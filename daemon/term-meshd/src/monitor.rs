use serde::Serialize;
use std::collections::{HashMap, HashSet};
use sysinfo::{Pid, ProcessesToUpdate, System};
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
    pub cpu_count: usize,
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
            auto_stop: true,
        }
    }
}

/// Detect the daemon's parent PID (typically the Swift app).
fn detect_root_pid(sys: &mut System) -> Option<u32> {
    let my_pid = std::process::id();
    sys.refresh_processes(ProcessesToUpdate::Some(&[Pid::from_u32(my_pid)]), true);
    let parent = sys
        .process(Pid::from_u32(my_pid))
        .and_then(|p| p.parent())
        .map(|p| p.as_u32());
    if let Some(ppid) = parent {
        tracing::info!("auto-discovery root PID: {ppid} (daemon parent)");
    }
    parent
}

/// BFS to find all descendant PIDs of root_pid.
fn find_descendants(sys: &System, root_pid: u32) -> HashSet<u32> {
    let mut children_map: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, proc_info) in sys.processes() {
        if let Some(ppid) = proc_info.parent() {
            children_map
                .entry(ppid.as_u32())
                .or_default()
                .push(pid.as_u32());
        }
    }

    let mut result = HashSet::new();
    let mut queue: Vec<u32> = children_map.get(&root_pid).cloned().unwrap_or_default();
    while let Some(pid) = queue.pop() {
        if result.insert(pid) {
            if let Some(kids) = children_map.get(&pid) {
                queue.extend(kids);
            }
        }
    }
    result
}

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
    let daemon_pid = std::process::id();

    tokio::spawn(async move {
        let mut sys = System::new_all();
        let mut tick = interval(Duration::from_secs(2));

        // Detect root PID (parent of daemon = Swift app)
        let root_pid = detect_root_pid(&mut sys);

        loop {
            tick.tick().await;
            sys.refresh_memory();
            sys.refresh_cpu_usage();

            // Refresh ALL processes for auto-discovery
            sys.refresh_processes(ProcessesToUpdate::All, true);

            // Auto-discover descendants of root PID
            if let Some(root) = root_pid {
                let descendants = find_descendants(&sys, root);
                let mut tracked = pids.lock().unwrap();

                for &pid in &descendants {
                    if pid != daemon_pid && !tracked.contains(&pid) {
                        tracked.push(pid);
                        tracing::debug!("auto-tracked PID {pid}");
                    }
                }

                // Remove dead PIDs
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

            let snapshot = SystemSnapshot {
                timestamp_ms: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64,
                total_memory_bytes: sys.total_memory(),
                used_memory_bytes: sys.used_memory(),
                cpu_count: sys.cpus().len(),
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

    // ── find_descendants tests ──

    #[test]
    fn find_descendants_returns_children() {
        // Use the real system — find descendants of PID 1 (launchd)
        let sys = System::new_all();
        let descendants = find_descendants(&sys, 1);
        // PID 1 (launchd) should have many descendants on any macOS system
        assert!(!descendants.is_empty());
        // PID 1 itself should NOT be in the descendants
        assert!(!descendants.contains(&1));
    }

    #[test]
    fn find_descendants_nonexistent_pid() {
        let sys = System::new_all();
        // Use an impossibly high PID
        let descendants = find_descendants(&sys, u32::MAX);
        assert!(descendants.is_empty());
    }

    #[test]
    fn find_descendants_no_cycles() {
        // Ensure BFS terminates even with the full process tree
        let sys = System::new_all();
        let descendants = find_descendants(&sys, 1);
        // If BFS had a cycle bug, this would hang. Completing is the assertion.
        let _ = descendants.len();
    }

    // ── BudgetConfig defaults ──

    #[test]
    fn budget_config_defaults() {
        let config = BudgetConfig::default();
        assert_eq!(config.cpu_threshold_percent, 90.0);
        assert_eq!(config.memory_threshold_bytes, 4 * 1024 * 1024 * 1024);
        assert!(config.auto_stop);
    }

    // ── MonitorHandle PID tracking ──

    #[test]
    fn monitor_handle_track_untrack() {
        let handle = MonitorHandle {
            tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            stopped_pids: std::sync::Arc::new(std::sync::Mutex::new(HashSet::new())),
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
            auto_stop: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
            cpu_threshold: 90.0,
            memory_threshold: 4 * 1024 * 1024 * 1024,
        };

        assert!(handle.is_auto_stop());
        handle.set_auto_stop(false);
        assert!(!handle.is_auto_stop());
        handle.set_auto_stop(true);
        assert!(handle.is_auto_stop());
    }
}
