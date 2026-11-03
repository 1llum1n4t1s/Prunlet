fn main() {
    std::process::exit(prunlet::cli::run(
        std::env::args_os().skip(1).collect(),
        prunlet::cli::Host::Cli,
    ));
}
