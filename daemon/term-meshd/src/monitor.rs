use serde::Serialize;
use std::collections::HashSet;
use sysinfo::{Disks, Pid, ProcessesToUpdate, System};
use tokio::sync::watch;
use tokio::time::{interval, Duration};

/// Snapshot of a single process's resource usage.
#[derive(Debug, Clone, Serialize)]
pub struct ProcessSnapshot {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub memory_bytes: u64,
    pub stopped: bool,
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
    /// Disk totals
    pub disk_total_bytes: u64,
    pub disk_available_bytes: u64,
    /// Aggregate disk I/O from tracked processes (bytes since last tick)
    pub disk_read_bytes_per_sec: u64,
    pub disk_write_bytes_per_sec: u64,
    /// Per-process stats for tracked PIDs
    pub processes: Vec<ProcessSnapshot>,
    /// Budget guard alerts
    pub alerts: Vec<BudgetAlert>,
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

/// Start background resource monitor with auto-process-discovery.
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
        let mut sys = System::new_all();
        let mut disks = Disks::new_with_refreshed_list();
        let mut tick = interval(Duration::from_secs(2));
        let mut tick_count: u64 = 0;

        loop {
            tick.tick().await;
            tick_count += 1;
            sys.refresh_memory();
            sys.refresh_cpu_usage();
            // Refresh all processes every tick for system-wide disk I/O
            sys.refresh_processes(ProcessesToUpdate::All, true);
            // Refresh disk space every 15 ticks (30s)
            if tick_count % 15 == 1 {
                disks.refresh(false);
            }

            // Only refresh tracked PIDs (registered by Swift app via monitor.track RPC)
            let tracked_snapshot: Vec<u32> = pids.lock().unwrap().clone();
            let pids_to_refresh: Vec<Pid> = tracked_snapshot.iter().map(|&p| Pid::from_u32(p)).collect();
            if !pids_to_refresh.is_empty() {
                sys.refresh_processes(ProcessesToUpdate::Some(&pids_to_refresh), true);
            }

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

            let tracked: Vec<u32> = pids.lock().unwrap().clone();
            let stopped_set: HashSet<u32> = stopped.lock().unwrap().clone();
            let should_auto_stop = auto_stop.load(std::sync::atomic::Ordering::Relaxed);

            let mut processes = Vec::new();
            let mut alerts = Vec::new();

            for &pid in &tracked {
                if let Some(proc) = sys.process(Pid::from_u32(pid)) {
                    let cpu = proc.cpu_usage();
                    let mem = proc.memory();
                    let is_stopped = stopped_set.contains(&pid);
                    let name = proc.name().to_string_lossy().into_owned();

                    processes.push(ProcessSnapshot {
                        pid,
                        name: name.clone(),
                        cpu_percent: cpu,
                        memory_bytes: mem,
                        stopped: is_stopped,
                    });

                    // Skip threshold checks for already-stopped processes
                    if is_stopped { continue; }

                    if cpu > config.cpu_threshold_percent {
                        let action = if should_auto_stop {
                            if send_signal(pid, libc::SIGSTOP) {
                                stopped.lock().unwrap().insert(pid);
                                tracing::warn!("SIGSTOP sent to PID {pid} ({name}): CPU {cpu:.1}% > {:.1}%", config.cpu_threshold_percent);
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
                    }
                    if mem > config.memory_threshold_bytes {
                        let action = if should_auto_stop {
                            if send_signal(pid, libc::SIGSTOP) {
                                stopped.lock().unwrap().insert(pid);
                                tracing::warn!("SIGSTOP sent to PID {pid} ({name}): mem {mem} > {}", config.memory_threshold_bytes);
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

            // Disk space
            let (disk_total, disk_avail) = disks.list().iter().fold((0u64, 0u64), |(t, a), d| {
                (t + d.total_space(), a + d.available_space())
            });

            // System-wide disk I/O: aggregate across ALL processes
            // disk_usage().read_bytes is bytes since last refresh (already a delta)
            let (io_read, io_write) = sys.processes().values().fold((0u64, 0u64), |(r, w), proc| {
                let du = proc.disk_usage();
                (r + du.read_bytes, w + du.written_bytes)
            });
            let read_per_sec = io_read / 2; // 2s interval
            let write_per_sec = io_write / 2;

            let total_mem = sys.total_memory();
            let used_mem = sys.used_memory();
            let mem_pct = if total_mem > 0 { (used_mem as f64 / total_mem as f64 * 100.0) as f32 } else { 0.0 };

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
        let mut pids = self.tracked_pids.lock().unwrap();
        pids.retain(|&p| p != pid);
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
        self.auto_stop.store(enabled, std::sync::atomic::Ordering::Relaxed);
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
