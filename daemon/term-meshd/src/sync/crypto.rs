use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use zeroize::Zeroizing;

pub const NONCE_BYTES: usize = 24;
pub const TAG_BYTES: usize = 16;

pub struct ProjectKey(Zeroizing<[u8; 32]>);

impl ProjectKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(Zeroizing::new(bytes))
    }

    pub(crate) fn from_zeroizing(bytes: Zeroizing<[u8; 32]>) -> Self {
        Self(bytes)
    }

    pub(crate) fn expose_for_wrapping(&self) -> &[u8; 32] {
        &self.0
    }

    pub(crate) fn rotation_commitment(&self, project_id: &[u8; 32], key_id: &[u8; 16]) -> [u8; 32] {
        let mut input = [0_u8; 76];
        input[..28].copy_from_slice(b"term-mesh DEK commitment v1\0");
        input[28..60].copy_from_slice(project_id);
        input[60..].copy_from_slice(key_id);
        *blake3::keyed_hash(&self.0, &input).as_bytes()
    }

    pub(crate) fn keyed_hash(&self, input: &[u8]) -> [u8; 32] {
        *blake3::keyed_hash(&*self.0, input).as_bytes()
    }

    pub(crate) fn encrypt(
        &self,
        nonce: &[u8; NONCE_BYTES],
        plaintext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let cipher =
            XChaCha20Poly1305::new_from_slice(&*self.0).map_err(|_| CryptoError::InvalidKey)?;
        cipher
            .encrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|_| CryptoError::Authentication)
    }

    pub(crate) fn decrypt(
        &self,
        nonce: &[u8; NONCE_BYTES],
        ciphertext: &[u8],
        aad: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let cipher =
            XChaCha20Poly1305::new_from_slice(&*self.0).map_err(|_| CryptoError::InvalidKey)?;
        cipher
            .decrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad,
                },
            )
            .map_err(|_| CryptoError::Authentication)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CryptoError {
    InvalidKey,
    Authentication,
}
