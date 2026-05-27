//! Build script for ds3-ffi.
//!
//! Generates C# P/Invoke bindings from the `extern "C"` functions in
//! `src/c_exports.rs` using csbindgen.

fn main() {
    // Generate C# NativeMethods.g.cs from the extern "C" functions.
    let out_dir = std::path::PathBuf::from("out");
    std::fs::create_dir_all(&out_dir).expect("Failed to create out/ directory");

    csbindgen::Builder::default()
        .input_extern_file("src/c_exports.rs")
        .csharp_dll_name("ds3_ffi")
        .csharp_namespace("DS3Drive.Core")
        .csharp_class_name("NativeMethods")
        .generate_csharp_file(out_dir.join("NativeMethods.g.cs"))
        .expect("Failed to generate C# bindings");

    println!("cargo:rerun-if-changed=src/c_exports.rs");
}
