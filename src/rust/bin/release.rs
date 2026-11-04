#[cfg(windows)]
#[path = "../json.rs"]
mod json;
#[cfg(windows)]
#[path = "../release/mod.rs"]
mod release;

fn main() {
    #[cfg(windows)]
    if let Err(error) = release::run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
    #[cfg(not(windows))]
    {
        eprintln!("The Windows release engine requires Windows.");
        std::process::exit(1);
    }
}
