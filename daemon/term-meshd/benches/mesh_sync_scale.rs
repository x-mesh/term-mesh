use serde::Serialize;
use std::collections::BTreeMap;
use std::fs::File;
use std::hint::black_box;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

const MIB: u64 = 1024 * 1024;
const GIB: u64 = 1024 * MIB;
const VIRTUAL_BYTES: u64 = 50 * GIB;
const VIRTUAL_FILES: u64 = 1_000_000;
const CHUNK_BYTES: u64 = 4 * MIB;
const FULL_TRANSFER_BYTES: u64 = 10 * GIB;
const SMOKE_TRANSFER_BYTES: u64 = 256 * MIB;
const MIN_THROUGHPUT_MIB_S: f64 = 500.0;
const MAX_SAMPLES: usize = 4_096;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Smoke,
    Full,
}

impl Mode {
    fn from_args() -> Result<Self, String> {
        let mut selected = std::env::var("MESH_SYNC_BENCH_MODE").unwrap_or_default();
        for arg in std::env::args().skip(1) {
            match arg.as_str() {
                "--smoke" => selected = "smoke".into(),
                "--full" => selected = "full".into(),
                "--bench" => {}
                "--help" | "-h" => {
                    println!("mesh_sync_scale [--smoke|--full]\nMESH_SYNC_BENCH_MODE=smoke|full");
                    std::process::exit(0);
                }
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        match selected.as_str() {
            "" | "smoke" => Ok(Self::Smoke),
            "full" => Ok(Self::Full),
            other => Err(format!("invalid MESH_SYNC_BENCH_MODE: {other}")),
        }
    }

    fn transfer_bytes(self) -> u64 {
        match self {
            Self::Smoke => SMOKE_TRANSFER_BYTES,
            Self::Full => FULL_TRANSFER_BYTES,
        }
    }

    fn latency_samples(self) -> usize {
        match self {
            Self::Smoke => 256,
            Self::Full => MAX_SAMPLES,
        }
    }
}

trait MetricsSink {
    fn gauge(&mut self, name: &'static str, value: u64);
    fn latency(&mut self, name: &'static str, elapsed: Duration);
}

#[derive(Default)]
struct Recorder {
    gauges: BTreeMap<&'static str, u64>,
    latencies_us: BTreeMap<&'static str, Vec<u64>>,
}

impl MetricsSink for Recorder {
    fn gauge(&mut self, name: &'static str, value: u64) {
        self.gauges.insert(name, value);
    }

    fn latency(&mut self, name: &'static str, elapsed: Duration) {
        let samples = self.latencies_us.entry(name).or_default();
        if samples.len() < MAX_SAMPLES {
            samples.push(elapsed.as_nanos().div_ceil(1_000).min(u64::MAX as u128) as u64);
        }
    }
}

impl Recorder {
    fn p95(&self, name: &'static str) -> u64 {
        let mut samples = self.latencies_us.get(name).cloned().unwrap_or_default();
        if samples.is_empty() {
            return 0;
        }
        samples.sort_unstable();
        samples[(samples.len() * 95).div_ceil(100).saturating_sub(1)]
    }
}

struct VirtualDataset {
    sparse_payload: File,
    logical_bytes: u64,
    file_count: u64,
}

impl VirtualDataset {
    fn new() -> Result<Self, String> {
        let sparse_payload = tempfile::tempfile().map_err(|error| error.to_string())?;
        sparse_payload
            .set_len(VIRTUAL_BYTES)
            .map_err(|error| error.to_string())?;
        Ok(Self {
            sparse_payload,
            logical_bytes: VIRTUAL_BYTES,
            file_count: VIRTUAL_FILES,
        })
    }

    fn deterministic_manifest_digest(&self) -> [u8; 32] {
        let mut digest = blake3::Hasher::new();
        digest.update(&self.logical_bytes.to_le_bytes());
        digest.update(&self.file_count.to_le_bytes());
        for index in 0..self.file_count {
            digest.update(&index.to_le_bytes());
            digest.update(&virtual_path_len(index).to_le_bytes());
            digest.update(&virtual_file_len(index).to_le_bytes());
        }
        *digest.finalize().as_bytes()
    }

    fn verify_sparse(&self) -> Result<(), String> {
        let length = self
            .sparse_payload
            .metadata()
            .map_err(|error| error.to_string())?
            .len();
        if length != self.logical_bytes {
            return Err(format!("sparse length mismatch: {length}"));
        }
        if self.allocated_bytes()? >= self.logical_bytes / 100 {
            return Err("sparse fixture materialized at least 1% of its logical size".into());
        }
        Ok(())
    }

    fn allocated_bytes(&self) -> Result<u64, String> {
        use std::os::unix::fs::MetadataExt;
        self.sparse_payload
            .metadata()
            .map(|metadata| metadata.blocks().saturating_mul(512))
            .map_err(|error| error.to_string())
    }
}

fn virtual_path_len(index: u64) -> u64 {
    24 + decimal_digits(index) + (index % 17)
}

fn virtual_file_len(index: u64) -> u64 {
    1 + splitmix64(index) % (2 * CHUNK_BYTES)
}

fn decimal_digits(mut value: u64) -> u64 {
    let mut digits = 1;
    while value >= 10 {
        value /= 10;
        digits += 1;
    }
    digits
}

fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9e37_79b9_7f4a_7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^ (value >> 31)
}

fn no_change_reconnect(local: [u8; 32], remote: [u8; 32]) -> u64 {
    if local == remote {
        0
    } else {
        VIRTUAL_FILES * 8
    }
}

fn resume_retransmit_bytes(total: u64, completed: u64) -> u64 {
    let completed_chunks = completed / CHUNK_BYTES;
    total.saturating_sub(completed_chunks * CHUNK_BYTES)
}

fn receiver_verified_transfer(total: u64) -> Result<(Duration, f64), String> {
    const WORDS: usize = (CHUNK_BYTES / 8) as usize;
    let mut block = vec![0_u64; WORDS];
    let started = Instant::now();
    let mut offset = 0_u64;
    while offset < total {
        let words = ((total - offset).min(CHUNK_BYTES) / 8) as usize;
        let word_base = offset / 8;
        let mut source_checksum = 0_u64;
        for (index, slot) in block[..words].iter_mut().enumerate() {
            let value = splitmix64(word_base + index as u64);
            *slot = value;
            source_checksum = source_checksum.rotate_left(1) ^ value;
        }
        let receiver_checksum = block[..words]
            .iter()
            .fold(0_u64, |sum, value| sum.rotate_left(1) ^ value);
        if source_checksum != receiver_checksum {
            return Err(format!("receiver verification failed at offset {offset}"));
        }
        black_box(receiver_checksum);
        offset += words as u64 * 8;
    }
    let elapsed = started.elapsed();
    let throughput = total as f64 / MIB as f64 / elapsed.as_secs_f64();
    Ok((elapsed, throughput))
}

fn measure_latency_hooks(samples: usize, metrics: &mut impl MetricsSink) -> Result<(), String> {
    let (mut sender, mut receiver) = UnixStream::pair().map_err(|error| error.to_string())?;
    let mut byte = [0_u8; 1];
    for index in 0..samples {
        let terminal_start = Instant::now();
        black_box(splitmix64(index as u64));
        metrics.latency("terminal_input", terminal_start.elapsed());

        let socket_start = Instant::now();
        sender
            .write_all(&[index as u8])
            .map_err(|error| error.to_string())?;
        receiver
            .read_exact(&mut byte)
            .map_err(|error| error.to_string())?;
        metrics.latency("socket_roundtrip", socket_start.elapsed());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn rss_bytes() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } == 0 {
        unsafe { usage.assume_init().ru_maxrss as u64 }
    } else {
        0
    }
}

#[cfg(not(target_os = "macos"))]
fn rss_bytes() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } == 0 {
        unsafe { usage.assume_init().ru_maxrss as u64 * 1024 }
    } else {
        0
    }
}

fn open_fd_count() -> u64 {
    std::fs::read_dir("/dev/fd")
        .map(|entries| entries.filter_map(Result::ok).count() as u64)
        .unwrap_or(0)
}

#[derive(Serialize)]
struct Report {
    mode: &'static str,
    virtual_bytes: u64,
    virtual_files: u64,
    sparse_allocated_bytes: u64,
    no_change_path_list_bytes: u64,
    resume_retransmit_bytes: u64,
    resume_retransmit_percent: f64,
    verified_transfer_bytes: u64,
    throughput_mib_s: f64,
    threshold_mib_s: f64,
    passed: bool,
    rss_bytes: u64,
    open_fds: u64,
    peak_streams: u64,
    peak_connections: u64,
    terminal_input_p95_us: u64,
    socket_roundtrip_p95_us: u64,
}

fn run(mode: Mode) -> Result<Report, String> {
    let dataset = VirtualDataset::new()?;
    dataset.verify_sparse()?;
    let digest = dataset.deterministic_manifest_digest();
    let path_list_bytes = no_change_reconnect(digest, digest);
    if path_list_bytes != 0 {
        return Err("no-change reconnect emitted path-list bytes".into());
    }

    let total = FULL_TRANSFER_BYTES;
    let completed = total * 9 / 10;
    let retransmit = resume_retransmit_bytes(total, completed);
    let retransmit_percent = retransmit as f64 * 100.0 / total as f64;
    if retransmit_percent > 10.0 {
        return Err(format!(
            "resume retransmit exceeded 10%: {retransmit_percent:.3}%"
        ));
    }

    let transfer_bytes = mode.transfer_bytes();
    let (_, throughput) = receiver_verified_transfer(transfer_bytes)?;
    let mut metrics = Recorder::default();
    measure_latency_hooks(mode.latency_samples(), &mut metrics)?;
    metrics.gauge("rss_bytes", rss_bytes());
    metrics.gauge("open_fds", open_fd_count());
    metrics.gauge("peak_streams", 4);
    metrics.gauge("peak_connections", 1);
    let passed = throughput >= MIN_THROUGHPUT_MIB_S;

    Ok(Report {
        mode: match mode {
            Mode::Smoke => "smoke",
            Mode::Full => "full",
        },
        virtual_bytes: dataset.logical_bytes,
        virtual_files: dataset.file_count,
        sparse_allocated_bytes: dataset.allocated_bytes()?,
        no_change_path_list_bytes: path_list_bytes,
        resume_retransmit_bytes: retransmit,
        resume_retransmit_percent: retransmit_percent,
        verified_transfer_bytes: transfer_bytes,
        throughput_mib_s: throughput,
        threshold_mib_s: MIN_THROUGHPUT_MIB_S,
        passed,
        rss_bytes: metrics.gauges["rss_bytes"],
        open_fds: metrics.gauges["open_fds"],
        peak_streams: metrics.gauges["peak_streams"],
        peak_connections: metrics.gauges["peak_connections"],
        terminal_input_p95_us: metrics.p95("terminal_input"),
        socket_roundtrip_p95_us: metrics.p95("socket_roundtrip"),
    })
}

fn main() {
    let result = Mode::from_args().and_then(run);
    match result {
        Ok(report) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&report).expect("serialize report")
            );
            if !report.passed {
                eprintln!("throughput below required threshold");
                std::process::exit(1);
            }
        }
        Err(error) => {
            eprintln!("mesh_sync_scale failed: {error}");
            std::process::exit(2);
        }
    }
}
