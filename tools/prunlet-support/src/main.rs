mod hook;
mod scan;

fn main() {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let rest: Vec<String> = args.collect();
    let result = match command.as_str() {
        "scan-failures" => scan::run(&rest),
        _ => Err(anyhow::anyhow!("Expected scan-failures.")),
    };
    if let Err(error) = result {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
