fn main() {
    println!("cargo:rerun-if-changed=proto/gem80rgb.proto");
    let fds = protox::compile(["proto/gem80rgb.proto"], ["proto"])
        .expect("protox failed to compile proto/gem80rgb.proto");
    prost_build::Config::new()
        .compile_fds(fds)
        .expect("prost_build failed to generate Rust code from FileDescriptorSet");
}
