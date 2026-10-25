use numbat::{
    Context, InterpreterResult, InterpreterSettings, module_importer::BuiltinModuleImporter,
    resolver::CodeSource, value::Value,
};
use std::process::ExitCode;

const MAX_EXPRESSION_LENGTH: usize = 200;
const MAX_RESULT_BYTES: usize = 4095; // Leave one byte for the protocol's newline.

// A separate process lets Invoque stop expensive expressions without risking its UI.
fn evaluate(expression: &str) -> Option<String> {
    if expression.is_empty()
        || expression.chars().count() > MAX_EXPRESSION_LENGTH
        || expression.chars().any(char::is_control)
    {
        return None;
    }

    // Only embedded modules are available. No user init, files, plotting or network.
    let mut context = Context::new(BuiltinModuleImporter::default());
    let mut settings = InterpreterSettings {
        print_fn: Box::new(|_| {}),
    };
    let _ = context
        .interpret_with_settings(&mut settings, "use prelude", CodeSource::Internal)
        .ok()?;

    // Parentheses require one expression, excluding declarations and module imports.
    let code = format!("({expression})");
    let (_, result) = context
        .interpret_with_settings(&mut settings, &code, CodeSource::Text)
        .ok()?;
    let InterpreterResult::Value(Value::Quantity(quantity)) = &result else {
        return None;
    };
    if !quantity.unsafe_value().to_f64().is_finite() {
        return None;
    }

    let text = result.value_as_string()?.to_string();
    if text.len() > MAX_RESULT_BYTES || text.chars().any(char::is_control) {
        return None;
    }
    Some(text)
}

fn main() -> ExitCode {
    let mut arguments = std::env::args().skip(1);
    let Some(expression) = arguments.next() else {
        return ExitCode::FAILURE;
    };
    if arguments.next().is_some() {
        return ExitCode::FAILURE;
    }
    if let Some(result) = evaluate(&expression) {
        println!("{result}");
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::evaluate;

    #[test]
    fn arithmetic_and_scientific_functions() {
        for (expression, expected) in [
            ("2+2*3", "8"),
            ("(3+4)*2", "14"),
            ("-5+3", "-2"),
            ("2^10", "1024"),
            ("sqrt(9)", "3"),
            ("sin(pi/2)", "1"),
            ("log10(100)", "2"),
            ("ln(e)", "1"),
        ] {
            assert_eq!(
                evaluate(expression).as_deref(),
                Some(expected),
                "{expression}"
            );
        }
    }

    #[test]
    fn units_preserve_case_and_convert_dimensions() {
        for (expression, expected) in [
            ("2 km -> m", "2000 m"),
            ("15 km/h * 30 min", "7.5 km"),
            ("1 MB -> kB", "1000 kB"),
            ("5 inch + 2 ft -> cm", "73.66 cm"),
        ] {
            assert_eq!(
                evaluate(expression).as_deref(),
                Some(expected),
                "{expression}"
            );
        }
        assert_ne!(evaluate("1 MB"), evaluate("1 mB"));
    }

    #[test]
    fn invalid_non_numeric_and_non_finite_results_are_absent() {
        for expression in [
            "",
            "hello",
            "2+",
            "(2+2",
            "2+2)",
            "1/0",
            "sqrt(-1)",
            "exp(10000)",
            "1 m + 1 s",
            "\"hello\"",
            "true",
            "[1, 2]",
            "let x = 5",
            "use prelude",
            "1)\nlet x = 5\n(2",
            "2+2; 3+3",
            "100 USD -> EUR",
            "print(2)",
        ] {
            assert_eq!(evaluate(expression), None, "{expression}");
        }
        assert_eq!(evaluate(&"(".repeat(201)), None);
    }
}
