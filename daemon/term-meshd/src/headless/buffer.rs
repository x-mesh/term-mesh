use std::collections::VecDeque;

/// Ring buffer for capturing subprocess stdout/stderr output line by line.
pub struct OutputBuffer {
    lines: VecDeque<String>,
    capacity: usize,
}

impl OutputBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            lines: VecDeque::with_capacity(capacity.min(1024)),
            capacity,
        }
    }

    /// Append a line to the buffer, evicting the oldest if at capacity.
    pub fn push(&mut self, line: String) {
        if self.lines.len() >= self.capacity {
            self.lines.pop_front();
        }
        self.lines.push_back(line);
    }

    /// Read the last `n` lines (or all if n >= total).
    pub fn tail(&self, n: usize) -> Vec<&str> {
        let start = self.lines.len().saturating_sub(n);
        self.lines.iter().skip(start).map(|s| s.as_str()).collect()
    }

    /// Total number of lines currently buffered.
    pub fn len(&self) -> usize {
        self.lines.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ring_buffer_eviction() {
        let mut buf = OutputBuffer::new(3);
        buf.push("a".into());
        buf.push("b".into());
        buf.push("c".into());
        buf.push("d".into());
        assert_eq!(buf.tail(10), vec!["b", "c", "d"]);
        assert_eq!(buf.len(), 3);
    }

    #[test]
    fn test_tail_fewer_than_available() {
        let mut buf = OutputBuffer::new(10);
        buf.push("1".into());
        buf.push("2".into());
        buf.push("3".into());
        assert_eq!(buf.tail(2), vec!["2", "3"]);
    }
}
