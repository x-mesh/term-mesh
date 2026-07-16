use super::{
    KeychainBackend, KeychainError, KeychainItem, KeychainProtection, PeerIdentityProvider,
    PresenceAction, PresenceCapability, PresenceGrantContext, RandomSource, UserPresenceAuthorizer,
};
use zeroize::Zeroizing;

pub fn device_secret_item(project_hex: &str, device_hex: &str, name: &str) -> KeychainItem {
    KeychainItem {
        service: format!("term-mesh.sync.{project_hex}.{device_hex}"),
        account: name.to_owned(),
        protection: KeychainProtection::AfterFirstUnlockThisDeviceOnly,
    }
}

pub fn project_dek_item(project_hex: &str, key_id_hex: &str) -> KeychainItem {
    KeychainItem {
        service: format!("term-mesh.sync.{project_hex}"),
        account: format!("dek.{key_id_hex}"),
        protection: KeychainProtection::AfterFirstUnlockThisDeviceOnly,
    }
}

fn recovery_material_item(context: PresenceGrantContext) -> KeychainItem {
    KeychainItem {
        service: format!(
            "term-mesh.sync.recovery.{}",
            hex::encode(context.project_id)
        ),
        account: format!("material.{}", hex::encode(context.target_id)),
        protection: KeychainProtection::WhenUnlockedThisDeviceOnlyUserPresence,
    }
}

pub fn recovery_sentinel_item(project_hex: &str) -> KeychainItem {
    KeychainItem {
        service: format!("term-mesh.sync.recovery.{project_hex}"),
        account: "presence-sentinel".to_owned(),
        protection: KeychainProtection::WhenUnlockedThisDeviceOnlyUserPresence,
    }
}

pub fn export_recovery<B: KeychainBackend, R: RandomSource, P: PeerIdentityProvider>(
    authorizer: &UserPresenceAuthorizer<B, R, P>,
    backend: &dyn KeychainBackend,
    capability: PresenceCapability,
    context: PresenceGrantContext,
) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
    if context.action != PresenceAction::ExportRecovery {
        return Err(KeychainError::WrongCapability);
    }
    authorizer.consume(capability, context)?;
    let secret = backend.get(&recovery_material_item(context))?;
    if *blake3::hash(&secret).as_bytes() != context.material_digest {
        return Err(KeychainError::MaterialDigestMismatch);
    }
    Ok(secret)
}

pub fn import_recovery<B: KeychainBackend, R: RandomSource, P: PeerIdentityProvider>(
    authorizer: &UserPresenceAuthorizer<B, R, P>,
    backend: &dyn KeychainBackend,
    capability: PresenceCapability,
    context: PresenceGrantContext,
    secret: &[u8],
) -> Result<(), KeychainError> {
    if context.action != PresenceAction::ImportRecovery {
        return Err(KeychainError::WrongCapability);
    }
    authorizer.consume(capability, context)?;
    if *blake3::hash(secret).as_bytes() != context.material_digest {
        return Err(KeychainError::MaterialDigestMismatch);
    }
    backend.put(&recovery_material_item(context), secret)
}

pub fn authorize_revoke<B: KeychainBackend, R: RandomSource, P: PeerIdentityProvider>(
    authorizer: &UserPresenceAuthorizer<B, R, P>,
    capability: PresenceCapability,
    context: PresenceGrantContext,
) -> Result<(), KeychainError> {
    if context.action != PresenceAction::RevokeDevice {
        return Err(KeychainError::WrongCapability);
    }
    authorizer.consume(capability, context)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Memory(Arc<Mutex<HashMap<(String, String), Vec<u8>>>>);
    impl KeychainBackend for Memory {
        fn put(&self, item: &KeychainItem, secret: &[u8]) -> Result<(), KeychainError> {
            self.0.lock().unwrap().insert(
                (item.service.clone(), item.account.clone()),
                secret.to_vec(),
            );
            Ok(())
        }
        fn get(&self, item: &KeychainItem) -> Result<Zeroizing<Vec<u8>>, KeychainError> {
            self.0
                .lock()
                .unwrap()
                .get(&(item.service.clone(), item.account.clone()))
                .cloned()
                .map(Zeroizing::new)
                .ok_or_else(|| KeychainError::Platform("OSStatus -25300".into()))
        }
        fn delete(&self, item: &KeychainItem) -> Result<(), KeychainError> {
            self.0
                .lock()
                .unwrap()
                .remove(&(item.service.clone(), item.account.clone()));
            Ok(())
        }
    }
    struct Random;
    impl RandomSource for Random {
        fn fill(&self, output: &mut [u8]) -> Result<(), KeychainError> {
            output.fill(0xa5);
            Ok(())
        }
    }
    struct Identity;
    impl PeerIdentityProvider for Identity {
        fn trusted_uid(&self) -> Result<u32, KeychainError> {
            Ok(501)
        }
    }

    #[test]
    fn recovery_io_derives_item_only_from_bound_grant_context() {
        let backend = Memory::default();
        let project = [1; 32];
        let target = [2; 32];
        let secret = b"recovery material";
        backend
            .put(&recovery_sentinel_item(&hex::encode(project)), b"sentinel")
            .unwrap();
        let authorizer = UserPresenceAuthorizer::new(backend.clone(), Random, Identity, 501);
        let import_context = PresenceGrantContext {
            action: PresenceAction::ImportRecovery,
            project_id: project,
            target_id: target,
            material_digest: *blake3::hash(secret).as_bytes(),
        };
        let import_grant = authorizer.authorize(import_context).unwrap();
        import_recovery(&authorizer, &backend, import_grant, import_context, secret).unwrap();
        assert_eq!(
            backend
                .get(&recovery_material_item(import_context))
                .unwrap()
                .as_slice(),
            secret
        );

        let export_context = PresenceGrantContext {
            action: PresenceAction::ExportRecovery,
            ..import_context
        };
        let export_grant = authorizer.authorize(export_context).unwrap();
        assert_eq!(
            export_recovery(&authorizer, &backend, export_grant, export_context)
                .unwrap()
                .as_slice(),
            secret
        );
    }
}
