use std::fmt;
use std::sync::Arc;

use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::rustls;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, Error, SignatureScheme};

use super::{DeviceTlsIdentity, TransportError, TransportPeerSnapshot, TrustStore};
use sync_protocol::SYNC_ALPN;

struct CertificatePinVerifier {
    trust: Arc<TrustStore>,
    provider: Arc<CryptoProvider>,
}

impl fmt::Debug for CertificatePinVerifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CertificatePinVerifier")
    }
}

impl CertificatePinVerifier {
    fn verify_pin(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
    ) -> Result<(), Error> {
        if !intermediates.is_empty() {
            return Err(Error::General("certificate chain is not allowed".into()));
        }
        self.trust
            .authorize_transport_certificate(end_entity.as_ref())
            .map(|_| ())
            .map_err(|_| Error::General("unapproved transport certificate".into()))
    }

    fn schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl ServerCertVerifier for CertificatePinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        self.verify_pin(end_entity, intermediates)?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

impl ClientCertVerifier for CertificatePinVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        self.verify_pin(end_entity, intermediates)?;
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

fn certificate_and_key(
    identity: &DeviceTlsIdentity,
) -> (Vec<CertificateDer<'static>>, PrivateKeyDer<'static>) {
    (
        vec![CertificateDer::from(identity.certificate_der.clone())],
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
            identity.private_key_der().to_vec(),
        )),
    )
}

pub fn client_config(
    trust: Arc<TrustStore>,
    identity: &DeviceTlsIdentity,
) -> Result<quinn::ClientConfig, TransportError> {
    client_config_with_alpn(trust, identity, SYNC_ALPN.to_vec())
}

pub(super) fn client_config_with_alpn(
    trust: Arc<TrustStore>,
    identity: &DeviceTlsIdentity,
    alpn: Vec<u8>,
) -> Result<quinn::ClientConfig, TransportError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(CertificatePinVerifier {
        trust,
        provider: provider.clone(),
    });
    let (certificates, key) = certificate_and_key(identity);
    let mut crypto = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(TransportError::Tls)?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(certificates, key)
        .map_err(TransportError::Tls)?;
    crypto.alpn_protocols = vec![alpn];
    crypto.enable_early_data = false;
    let quic = QuicClientConfig::try_from(crypto)
        .map_err(|error| TransportError::Configuration(error.to_string()))?;
    let mut config = quinn::ClientConfig::new(Arc::new(quic));
    config.transport_config(Arc::new(super::transport::bounded_transport_config()?));
    Ok(config)
}

pub fn server_config(
    trust: Arc<TrustStore>,
    identity: &DeviceTlsIdentity,
) -> Result<quinn::ServerConfig, TransportError> {
    server_config_with_alpn(trust, identity, SYNC_ALPN.to_vec())
}

pub(super) fn server_config_with_alpn(
    trust: Arc<TrustStore>,
    identity: &DeviceTlsIdentity,
    alpn: Vec<u8>,
) -> Result<quinn::ServerConfig, TransportError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(CertificatePinVerifier {
        trust,
        provider: provider.clone(),
    });
    let (certificates, key) = certificate_and_key(identity);
    let mut crypto = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(TransportError::Tls)?
        .with_client_cert_verifier(verifier)
        .with_single_cert(certificates, key)
        .map_err(TransportError::Tls)?;
    crypto.alpn_protocols = vec![alpn];
    crypto.max_early_data_size = 0;
    crypto.send_half_rtt_data = false;
    let quic = QuicServerConfig::try_from(crypto)
        .map_err(|error| TransportError::Configuration(error.to_string()))?;
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(quic));
    config.transport_config(Arc::new(super::transport::bounded_transport_config()?));
    Ok(config)
}

pub fn peer_snapshot(
    connection: &quinn::Connection,
    trust: &TrustStore,
) -> Result<TransportPeerSnapshot, TransportError> {
    let identity = connection
        .peer_identity()
        .ok_or(TransportError::MissingPeerIdentity)?;
    let certificates = identity
        .downcast::<Vec<CertificateDer<'static>>>()
        .map_err(|_| TransportError::MissingPeerIdentity)?;
    let certificate = certificates
        .first()
        .ok_or(TransportError::MissingPeerIdentity)?;
    trust
        .authorize_transport_certificate(certificate.as_ref())
        .map_err(Into::into)
}

pub fn verify_alpn(connection: &quinn::Connection) -> Result<(), TransportError> {
    let data = connection
        .handshake_data()
        .ok_or(TransportError::AlpnMismatch)?;
    let data = data
        .downcast::<quinn::crypto::rustls::HandshakeData>()
        .map_err(|_| TransportError::AlpnMismatch)?;
    if data.protocol.as_deref() != Some(SYNC_ALPN) {
        return Err(TransportError::AlpnMismatch);
    }
    Ok(())
}
