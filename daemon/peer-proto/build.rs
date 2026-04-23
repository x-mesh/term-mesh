use std::path::PathBuf;

fn main() {
    let proto_root = PathBuf::from("../../proto");
    let proto_file = proto_root.join("peer/v1/peer.proto");

    println!("cargo:rerun-if-changed={}", proto_file.display());

    let file_descriptors =
        protox::compile([&proto_file], [&proto_root]).expect("protox failed to compile peer.proto");

    prost_build::Config::new()
        .compile_fds(file_descriptors)
        .expect("prost_build failed to generate Rust bindings");
}
