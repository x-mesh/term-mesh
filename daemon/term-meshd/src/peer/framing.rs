//! Length-prefixed Protobuf framing for the peer-federation wire protocol.
//!
//! Each frame on the wire is a little-endian u32 byte length followed by a
//! Protobuf-encoded `Envelope`. Frames larger than `MAX_FRAME_BYTES` are rejected.

use std::io;

use peer_proto::v1::Envelope;
use peer_proto::MAX_FRAME_BYTES;
use prost::Message;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub async fn read_envelope<R: AsyncRead + Unpin>(reader: &mut R) -> io::Result<Envelope> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    if len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    let mut buf = vec![0u8; len as usize];
    reader.read_exact(&mut buf).await?;
    Envelope::decode(buf.as_slice())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("decode: {e}")))
}

pub async fn write_envelope<W: AsyncWrite + Unpin>(
    writer: &mut W,
    envelope: &Envelope,
) -> io::Result<()> {
    let bytes = envelope.encode_to_vec();
    let len = bytes.len();
    if len > MAX_FRAME_BYTES as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds {MAX_FRAME_BYTES}"),
        ));
    }
    writer.write_all(&(len as u32).to_le_bytes()).await?;
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use peer_proto::v1::{envelope, Pong};
    use tokio::io::duplex;

    #[tokio::test]
    async fn roundtrip_via_duplex() {
        let (mut a, mut b) = duplex(4096);

        let env = Envelope {
            seq: 9,
            correlation_id: 0,
            payload: Some(envelope::Payload::Pong(Pong { nonce: 42 })),
        };
        write_envelope(&mut a, &env).await.unwrap();
        drop(a);

        let got = read_envelope(&mut b).await.unwrap();
        assert_eq!(got.seq, 9);
        match got.payload.unwrap() {
            envelope::Payload::Pong(p) => assert_eq!(p.nonce, 42),
            _ => panic!("wrong variant"),
        }
    }

    #[tokio::test]
    async fn rejects_oversized_frame() {
        let (mut a, mut b) = duplex(64);
        // Write a bogus length larger than MAX_FRAME_BYTES.
        let bad = (MAX_FRAME_BYTES + 1).to_le_bytes();
        tokio::io::AsyncWriteExt::write_all(&mut a, &bad)
            .await
            .unwrap();
        let err = read_envelope(&mut b).await.unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    /// P3 capability plumbing, wire boundary: a `Hello.capabilities` entry
    /// with invalid UTF-8 bytes must make `read_envelope` return a clean
    /// `InvalidData` error, not panic -- this is the function every caller
    /// (`connection::reader_loop`, the CLI client) actually calls, so this
    /// is the layer where the safety guarantee has to hold in practice.
    /// `peer_proto`'s own `capabilities_invalid_utf8_bytes_fail_decode_gracefully`
    /// covers the same corruption at the raw `Envelope::decode` level;
    /// this confirms it survives the length-prefix framing on top of that.
    #[tokio::test]
    async fn rejects_invalid_utf8_capability_bytes() {
        use peer_proto::v1::{envelope, Hello};

        let placeholder = "xxxxxxxx";
        let env = Envelope {
            seq: 1,
            correlation_id: 0,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: "1.0.0".into(),
                peer_id: vec![0xAB; 16],
                display_name: "corrupt-frame-test".into(),
                capabilities: vec![placeholder.to_string()],
                app_version: "test".into(),
                cli_bin_dirs: vec![],
            })),
        };
        let mut encoded = env.encode_to_vec();
        let marker = placeholder.as_bytes();
        let pos = encoded
            .windows(marker.len())
            .position(|w| w == marker)
            .expect("placeholder capability bytes not found in encoded message");
        for b in &mut encoded[pos..pos + marker.len()] {
            *b = 0x80; // never valid UTF-8 on its own
        }

        let (mut a, mut b) = duplex(4096);
        tokio::io::AsyncWriteExt::write_all(&mut a, &(encoded.len() as u32).to_le_bytes())
            .await
            .unwrap();
        tokio::io::AsyncWriteExt::write_all(&mut a, &encoded)
            .await
            .unwrap();

        let err = read_envelope(&mut b).await.unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }
}
