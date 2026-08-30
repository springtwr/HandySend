fn main() {
    #[cfg(feature = "napi")]
    {
        use napi_build_ohos::setup;
        setup();
    }

    println!("cargo:rerun-if-changed=src/");
}
