fn main() {
    match rust_cicd_core::checked_add(2, 3) {
        Some(v) => println!("{v}"),
        None => eprintln!("overflow"),
    }
}
