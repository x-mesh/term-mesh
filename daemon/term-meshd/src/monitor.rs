use serde::Serialize;
use std::collections::{HashMap, HashSet};
use sysinfo::{Disks, Networks, Pid, ProcessesToUpdate, System};
use tokio::sync::watch;
use tokio::time::{interval, Duration};

// Sustained high-CPU threshold: 15 ticks × 2s = 30 seconds
const HIGH_CPU_TICKS_THRESHOLD: u32 = 15;

/// Snapshot of a single process's resource usage.
#[derive(Debug, Clone, Serialize)]
pub struct ProcessSnapshot {
    pub pid: u32,
    pub ppid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub memory_bytes: u64,
    pub stopped: bool,
    /// First 200 chars of the command line (space-joined argv).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmdline: Option<String>,
    /// Seconds the process has been running.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_secs: Option<u64>,
    /// Number of threads (Linux only; None on macOS).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_count: Option<u32>,
}

/// Per-network-interface I/O.
#[derive(Debug, Clone, Serialize)]
pub struct NetworkIO {
    pub name: String,
    /// Total bytes received since process start.
    pub rx_bytes: u64,
    /// Total bytes transmitted since process start.
    pub tx_bytes: u64,
    /// Received bytes/sec (delta since last tick).
    pub rx_rate: f64,
    /// Transmitted bytes/sec (delta since last tick).
    pub tx_rate: f64,
}

/// Per-disk-mount space info.
#[derive(Debug, Clone, Serialize)]
pub struct DiskInfo {
    pub mount_point: String,
    pub total: u64,
    pub used: u64,
    pub available: u64,
}

/// Agent anomaly detected by the monitor.
#[derive(Debug, Clone, Serialize)]
pub struct Anomaly {
    pub agent_id: String,
    /// "no_heartbeat" | "repeated_failure" | "high_resource"
    pub kind: String,
    pub message: String,
    /// "warning" | "critical"
    pub severity: String,
    /// ISO 8601 UTC timestamp.
    pub detected_at: String,
}

/// System-wide resource snapshot.
#[derive(Debug, Clone, Serialize)]
pub struct SystemSnapshot {
    pub timestamp_ms: u64,
    pub total_memory_bytes: u64,
    pub used_memory_bytes: u64,
    pub memory_percent: f32,
    pub cpu_count: usize,
    pub cpu_usage_percent: f32,
    /// Disk totals (aggregate of all mounts)
    pub disk_total_bytes: u64,
    pub disk_available_bytes: u64,
    /// Aggregate disk I/O from tracked processes (bytes since last tick)
    pub disk_read_bytes_per_sec: u64,
    pub disk_write_bytes_per_sec: u64,
    /// Per-process stats for tracked PIDs
    pub processes: Vec<ProcessSnapshot>,
    /// Budget guard alerts
    pub alerts: Vec<BudgetAlert>,
    // ── New fields ──
    /// 1-minute, 5-minute, 15-minute load averages.
    pub load_avg: [f64; 3],
    /// Total swap memory in bytes.
    pub swap_total: u64,
    /// Used swap memory in bytes.
    pub swap_used: u64,
    /// Per-interface network I/O.
    pub network_io: Vec<NetworkIO>,
    /// Per-CPU-core usage percentages.
    pub per_core_cpu: Vec<f32>,
    /// Per-mount-point disk space breakdown.
    pub disk_space: Vec<DiskInfo>,
    /// Anomalies detected by the resource monitor (high_resource).
    /// no_heartbeat / repeated_failure are injected in socket.rs.
    #[serde(default)]
    pub anomalies: Vec<Anomaly>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BudgetAlert {
    pub pid: u32,
    pub name: String,
    pub kind: String, // "cpu" | "memory"
    pub value: f64,
    pub threshold: f64,
    pub action: String, // "warning" | "stopped"
}

#[derive(Debug, Clone)]
pub struct BudgetConfig {
    pub cpu_threshold_percent: f32,
    pub memory_threshold_bytes: u64,
    pub auto_stop: bool,
}

impl Default for BudgetConfig {
    fn default() -> Self {
        Self {
            cpu_threshold_percent: 90.0,
            memory_threshold_bytes: 4 * 1024 * 1024 * 1024, // 4 GB
            auto_stop: false,
        }
    }
}

// NOTE: Auto-discovery via root PID was removed. When the daemon is started
// independently (e.g. nohup/make deploy), its parent is PID 1 (launchd),
// causing find_descendants to return ALL system processes.
// The Swift app's DashboardController now handles PID discovery and registers
// the correct descendant PIDs via monitor.track RPC.

/// Send a Unix signal to a process. Returns true on success.
fn send_signal(pid: u32, signal: i32) -> bool {
    unsafe { libc::kill(pid as i32, signal) == 0 }
}

/// Refresh only the processes explicitly registered by the app.
fn refresh_tracked_processes(system: &mut System, tracked: &[u32]) {
    let pids: Vec<Pid> = tracked.iter().copied().map(Pid::from_u32).collect();
    if !pids.is_empty() {
        system.refresh_processes(ProcessesToUpdate::Some(&pids), true);
    }
}

fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    // Simple ISO 8601 UTC formatter without chrono dependency.
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Julian Date → Gregorian calendar (Meeus algorithm)
    let jd = days as i64 + 2440588; // 1970-01-01 = JD 2440588
    let p = jd + 68569;
    let q = 4 * p / 146097;
    let r = p - (146097 * q + 3) / 4;
    let s2 = 4000 * (r + 1) / 1461001;
    let r2 = r - 1461 * s2 / 4 + 31;
    let month = 80 * r2 / 2447;
    let day = r2 - 2447 * month / 80;
    let month2 = month + 2 - 12 * (month / 11);
    let year = 100 * (q - 49) + s2 + month / 11;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month2, day, h, m, s
    )
}

/// Start the background resource monitor for app-registered processes.
/// Watch paths are managed separately by the Swift app (per terminal tab).
pub fn start_monitor(
    config: BudgetConfig,
) -> (watch::Receiver<Option<SystemSnapshot>>, MonitorHandle) {
    let (tx, rx) = watch::channel(None);
    let handle = MonitorHandle {
        tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
        stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::new())),
        auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(config.auto_stop)),
        cpu_threshold: config.cpu_threshold_percent,
        memory_threshold: config.memory_threshold_bytes,
    };
    let pids = handle.tracked_pids.clone();
    let stopped = handle.stopped_pids.clone();
    let auto_stop = handle.auto_stop.clone();
    tokio::spawn(async move {
        // Process discovery belongs to the Swift app, which registers exactly
        // the PIDs this monitor needs. `System::new_all()` eagerly enumerates
        // every process at startup, and refreshing `ProcessesToUpdate::All` on
        // each tick made the daemon spike every two seconds even when no agent
        // was running. Start empty and populate only registered PIDs below.
        let mut sys = System::new();
        let mut disks = Disks::new_with_refreshed_list();
        let mut networks = Networks::new_with_refreshed_list();
        let mut tick = interval(Duration::from_secs(2));
        let mut tick_count: u64 = 0;
        // Track previous per-interface totals for rate calculation.
        let mut prev_net: HashMap<String, (u64, u64)> = HashMap::new();
        // Track consecutive ticks where each PID exceeded the CPU threshold.
        let mut high_cpu_ticks: HashMap<u32, u32> = HashMap::new();

        loop {
            tick.tick().await;
            tick_count += 1;
            sys.refresh_memory();
            sys.refresh_cpu_usage();
            // Refresh disk space every 15 ticks (30s)
            if tick_count % 15 == 1 {
                disks.refresh(false);
            }
            // Refresh network stats every tick
            networks.refresh(false);

            // Only refresh tracked PIDs (registered by Swift app via monitor.track RPC).
            // `remove_dead_processes` remains true so a registered process that
            // exits disappears from both sysinfo and the tracked list below.
            let tracked_snapshot: Vec<u32> = pids.lock().unwrap().clone();
            refresh_tracked_processes(&mut sys, &tracked_snapshot);

            // Remove dead PIDs from tracked list
            {
                let mut tracked = pids.lock().unwrap();
                tracked.retain(|&pid| sys.process(Pid::from_u32(pid)).is_some());
            }

            // Clean up stopped set for dead processes
            {
                let mut stopped_set = stopped.lock().unwrap();
                stopped_set.retain(|&pid| sys.process(Pid::from_u32(pid)).is_some());
            }
            // Clean up high_cpu_ticks for dead processes
            high_cpu_ticks.retain(|&pid, _| sys.process(Pid::from_u32(pid)).is_some());

            let tracked: Vec<u32> = pids.lock().unwrap().clone();
            let stopped_set: HashSet<u32> = stopped.lock().unwrap().clone();
            let should_auto_stop = auto_stop.load(std::sync::atomic::Ordering::Relaxed);

            let mut processes = Vec::new();
            let mut alerts = Vec::new();
            let mut anomalies: Vec<Anomaly> = Vec::new();

            let mut io_read = 0u64;
            let mut io_write = 0u64;
            for &pid in &tracked {
                if let Some(proc) = sys.process(Pid::from_u32(pid)) {
                    let cpu = proc.cpu_usage();
                    let mem = proc.memory();
                    let is_stopped = stopped_set.contains(&pid);
                    let name = proc.name().to_string_lossy().into_owned();
                    let ppid = proc.parent().map(|p| p.as_u32()).unwrap_or(0);
                    let disk_usage = proc.disk_usage();
                    io_read = io_read.saturating_add(disk_usage.read_bytes);
                    io_write = io_write.saturating_add(disk_usage.written_bytes);

                    // cmdline: join argv, truncate to 200 chars
                    let cmdline: Option<String> = {
                        let args: Vec<String> = proc
                            .cmd()
                            .iter()
                            .map(|a| a.to_string_lossy().into_owned())
                            .collect();
                        if args.is_empty() {
                            None
                        } else {
                            let joined = args.join(" ");
                            Some(if joined.len() > 200 {
                                joined[..200].to_string()
                            } else {
                                joined
                            })
                        }
                    };

                    let runtime_secs: Option<u64> = Some(proc.run_time());

                    // thread_count: available on Linux via tasks(); None on macOS
                    let thread_count: Option<u32> = proc.tasks().map(|t| t.len() as u32);

                    processes.push(ProcessSnapshot {
                        pid,
                        ppid,
                        name: name.clone(),
                        cpu_percent: cpu,
                        memory_bytes: mem,
                        stopped: is_stopped,
                        cmdline,
                        runtime_secs,
                        thread_count,
                    });

                    // Skip threshold checks for already-stopped processes
                    if is_stopped {
                        continue;
                    }

                    if cpu > config.cpu_threshold_percent {
                        let action = if should_auto_stop {
                            if send_signal(pid, libc::SIGSTOP) {
                                stopped.lock().unwrap().insert(pid);
                                tracing::warn!(
                                    "SIGSTOP sent to PID {pid} ({name}): CPU {cpu:.1}% > {:.1}%",
                                    config.cpu_threshold_percent
                                );
                                "stopped"
                            } else {
                                "warning"
                            }
                        } else {
                            "warning"
                        };
                        alerts.push(BudgetAlert {
                            pid,
                            name: name.clone(),
                            kind: "cpu".into(),
                            value: cpu as f64,
                            threshold: config.cpu_threshold_percent as f64,
                            action: action.into(),
                        });

                        // Track sustained high CPU for anomaly detection
                        let count = high_cpu_ticks.entry(pid).or_insert(0);
                        *count += 1;
                        if *count == HIGH_CPU_TICKS_THRESHOLD {
                            anomalies.push(Anomaly {
                                agent_id: format!("pid:{pid}"),
                                kind: "high_resource".into(),
                                message: format!(
                                    "Process '{name}' (PID {pid}) sustained {cpu:.1}% CPU for 30s",
                                ),
                                severity: "warning".into(),
                                detected_at: iso8601_now(),
                            });
                        }
                    } else {
                        // Reset counter when CPU drops below threshold
                        high_cpu_ticks.remove(&pid);
                    }

                    if mem > config.memory_threshold_bytes {
                        let action = if should_auto_stop {
                            if send_signal(pid, libc::SIGSTOP) {
                                stopped.lock().unwrap().insert(pid);
                                tracing::warn!(
                                    "SIGSTOP sent to PID {pid} ({name}): mem {mem} > {}",
                                    config.memory_threshold_bytes
                                );
                                "stopped"
                            } else {
                                "warning"
                            }
                        } else {
                            "warning"
                        };
                        alerts.push(BudgetAlert {
                            pid,
                            name: name.clone(),
                            kind: "memory".into(),
                            value: mem as f64,
                            threshold: config.memory_threshold_bytes as f64,
                            action: action.into(),
                        });
                    }
                }
            }

            // System-wide CPU
            let cpu_usage = sys.global_cpu_usage();

            // Per-core CPU
            let per_core_cpu: Vec<f32> = sys.cpus().iter().map(|c| c.cpu_usage()).collect();

            // Disk space
            let (disk_total, disk_avail) = disks.list().iter().fold((0u64, 0u64), |(t, a), d| {
                (t + d.total_space(), a + d.available_space())
            });

            let disk_space: Vec<DiskInfo> = disks
                .list()
                .iter()
                .map(|d| {
                    let total = d.total_space();
                    let avail = d.available_space();
                    let used = total.saturating_sub(avail);
                    DiskInfo {
                        mount_point: d.mount_point().to_string_lossy().into_owned(),
                        total,
                        used,
                        available: avail,
                    }
                })
                .collect();

            // Aggregate only registered processes. disk_usage().read_bytes and
            // written_bytes are deltas since the preceding refresh.
            let read_per_sec = io_read / 2; // 2s interval
            let write_per_sec = io_write / 2;

            // Network I/O with rate calculation
            let mut network_io: Vec<NetworkIO> = Vec::new();
            for (iface_name, data) in networks.iter() {
                let rx_total = data.total_received();
                let tx_total = data.total_transmitted();
                let (rx_rate, tx_rate) = if let Some(&(prev_rx, prev_tx)) = prev_net.get(iface_name)
                {
                    let rx_delta = rx_total.saturating_sub(prev_rx);
                    let tx_delta = tx_total.saturating_sub(prev_tx);
                    (rx_delta as f64 / 2.0, tx_delta as f64 / 2.0) // 2s interval
                } else {
                    (0.0, 0.0)
                };
                prev_net.insert(iface_name.clone(), (rx_total, tx_total));
                network_io.push(NetworkIO {
                    name: iface_name.clone(),
                    rx_bytes: rx_total,
                    tx_bytes: tx_total,
                    rx_rate,
                    tx_rate,
                });
            }

            // Load average
            let la = System::load_average();
            let load_avg = [la.one, la.five, la.fifteen];

            // Swap
            let swap_total = sys.total_swap();
            let swap_used = sys.used_swap();

            let total_mem = sys.total_memory();
            let used_mem = sys.used_memory();
            let mem_pct = if total_mem > 0 {
                (used_mem as f64 / total_mem as f64 * 100.0) as f32
            } else {
                0.0
            };

            let snapshot = SystemSnapshot {
                timestamp_ms: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64,
                total_memory_bytes: total_mem,
                used_memory_bytes: used_mem,
                memory_percent: mem_pct,
                cpu_count: sys.cpus().len(),
                cpu_usage_percent: cpu_usage,
                disk_total_bytes: disk_total,
                disk_available_bytes: disk_avail,
                disk_read_bytes_per_sec: read_per_sec,
                disk_write_bytes_per_sec: write_per_sec,
                processes,
                alerts,
                load_avg,
                swap_total,
                swap_used,
                network_io,
                per_core_cpu,
                disk_space,
                anomalies,
            };

            let _ = tx.send(Some(snapshot));
        }
    });

    (rx, handle)
}

/// Handle to add/remove tracked PIDs and control process signals.
#[derive(Clone)]
pub struct MonitorHandle {
    tracked_pids: std::sync::Arc<std::sync::Mutex<Vec<u32>>>,
    stopped_pids: std::sync::Arc<std::sync::Mutex<HashSet<u32>>>,
    auto_stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    cpu_threshold: f32,
    memory_threshold: u64,
}

impl MonitorHandle {
    pub fn track_pid(&self, pid: u32) {
        let mut pids = self.tracked_pids.lock().unwrap();
        if !pids.contains(&pid) {
            pids.push(pid);
            tracing::info!("tracking PID {pid}");
        }
    }

    pub fn untrack_pid(&self, pid: u32) {
        {
            let mut pids = self.tracked_pids.lock().unwrap();
            pids.retain(|&p| p != pid);
        }
        // A stopped process can outlive its tracking relationship. Resume it
        // before forgetting the PID and always clear membership so PID reuse
        // cannot make a new process look already stopped.
        if self.stopped_pids.lock().unwrap().remove(&pid) {
            let _ = send_signal(pid, libc::SIGCONT);
        }
        tracing::info!("untracked PID {pid}");
    }

    pub fn tracked_pids(&self) -> Vec<u32> {
        self.tracked_pids.lock().unwrap().clone()
    }

    /// Send SIGSTOP to a process.
    pub fn stop_process(&self, pid: u32) -> bool {
        if send_signal(pid, libc::SIGSTOP) {
            self.stopped_pids.lock().unwrap().insert(pid);
            tracing::warn!("manual SIGSTOP sent to PID {pid}");
            true
        } else {
            tracing::error!("failed to SIGSTOP PID {pid}");
            false
        }
    }

    /// Send SIGCONT to resume a stopped process.
    pub fn resume_process(&self, pid: u32) -> bool {
        if send_signal(pid, libc::SIGCONT) {
            self.stopped_pids.lock().unwrap().remove(&pid);
            tracing::info!("SIGCONT sent to PID {pid}");
            true
        } else {
            tracing::error!("failed to SIGCONT PID {pid}");
            false
        }
    }

    /// Set auto-stop mode.
    pub fn set_auto_stop(&self, enabled: bool) {
        self.auto_stop
            .store(enabled, std::sync::atomic::Ordering::Relaxed);
        tracing::info!("auto-stop set to {enabled}");
    }

    pub fn is_auto_stop(&self) -> bool {
        self.auto_stop.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Resume all stopped processes (SIGCONT) and clear the stopped set.
    /// Used during graceful shutdown to avoid leaving orphaned stopped processes.
    pub fn resume_all_stopped(&self) -> usize {
        let mut stopped = self.stopped_pids.lock().unwrap();
        let mut resumed = 0;
        for &pid in stopped.iter() {
            if send_signal(pid, libc::SIGCONT) {
                tracing::info!("shutdown: SIGCONT sent to PID {pid}");
                resumed += 1;
            } else {
                tracing::warn!("shutdown: failed to SIGCONT PID {pid} (may have exited)");
            }
        }
        stopped.clear();
        resumed
    }

    pub fn cpu_threshold(&self) -> f32 {
        self.cpu_threshold
    }

    pub fn memory_threshold(&self) -> u64 {
        self.memory_threshold
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracked_refresh_does_not_enumerate_unregistered_processes() {
        let mut system = System::new();
        let current = std::process::id();

        refresh_tracked_processes(&mut system, &[current]);

        assert!(system.process(Pid::from_u32(current)).is_some());
        assert_eq!(system.processes().len(), 1);
    }

    // ── BudgetConfig defaults ──

    #[test]
    fn budget_config_defaults() {
        let config = BudgetConfig::default();
        assert_eq!(config.cpu_threshold_percent, 90.0);
        assert_eq!(config.memory_threshold_bytes, 4 * 1024 * 1024 * 1024);
        assert!(!config.auto_stop);
    }

    // ── MonitorHandle PID tracking ──

    #[test]
    fn monitor_handle_track_untrack() {
        let handle = MonitorHandle {
            tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::new())),
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            cpu_threshold: 90.0,
            memory_threshold: 4 * 1024 * 1024 * 1024,
        };

        assert!(handle.tracked_pids().is_empty());

        handle.track_pid(1234);
        assert_eq!(handle.tracked_pids(), vec![1234]);

        // Duplicate tracking should not add twice
        handle.track_pid(1234);
        assert_eq!(handle.tracked_pids(), vec![1234]);

        handle.track_pid(5678);
        assert_eq!(handle.tracked_pids().len(), 2);

        handle.untrack_pid(1234);
        assert_eq!(handle.tracked_pids(), vec![5678]);

        handle.untrack_pid(5678);
        assert!(handle.tracked_pids().is_empty());
    }

    #[test]
    fn untrack_clears_stopped_membership_for_pid_reuse() {
        let handle = MonitorHandle {
            tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(vec![99999])),
            stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::from([99999]))),
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            cpu_threshold: 90.0,
            memory_threshold: 4 * 1024 * 1024 * 1024,
        };

        handle.untrack_pid(99999);

        assert!(handle.tracked_pids().is_empty());
        assert!(handle.stopped_pids.lock().unwrap().is_empty());
    }

    #[test]
    fn monitor_handle_resume_all_stopped() {
        let handle = MonitorHandle {
            tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::new())),
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            cpu_threshold: 90.0,
            memory_threshold: 4 * 1024 * 1024 * 1024,
        };

        // Manually insert fake PIDs into stopped set
        handle.stopped_pids.lock().unwrap().insert(99999);
        handle.stopped_pids.lock().unwrap().insert(99998);
        assert_eq!(handle.stopped_pids.lock().unwrap().len(), 2);

        // resume_all_stopped should clear the set (signals will fail for fake PIDs, that's fine)
        let _resumed = handle.resume_all_stopped();
        assert!(handle.stopped_pids.lock().unwrap().is_empty());
    }

    #[test]
    fn monitor_handle_auto_stop_toggle() {
        let handle = MonitorHandle {
            tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::new())),
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            cpu_threshold: 90.0,
            memory_threshold: 4 * 1024 * 1024 * 1024,
        };

        assert!(!handle.is_auto_stop());
        handle.set_auto_stop(true);
        assert!(handle.is_auto_stop());
        handle.set_auto_stop(false);
        assert!(!handle.is_auto_stop());
    }
}
