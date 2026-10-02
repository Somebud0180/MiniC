import Foundation

public struct ProbeResult: Codable, Sendable {
    public let name: String
    public let passed: Bool
    public let output: String
    public let exitCode: UInt32?
    public let failure: String?
}
public enum PrototypeVerification {
    public static func run(compiler: OfflineCompiler) async -> [ProbeResult] {
        var results: [ProbeResult] = []
        for example in CompilerExample.all {
            let result = await compiler.run(source: example.source, language: example.language, input: example.input)
            let passed: Bool
            if let expected = example.expected { passed = result.succeeded && result.output == expected }
            else {
                switch example.id {
                case "Invalid source": passed = result.failure?.contains("undeclared identifier") == true
                case "Infinite loop": passed = result.failure?.lowercased().contains("fuel") == true
                case "Output limit": passed = result.failure?.contains("Output exceeded") == true
                case "C++ exceptions (unsupported)": passed = result.failure?.contains("exceptions disabled") == true
                default: passed = false
                }
            }
            results.append(.init(name: example.id, passed: passed, output: String(result.output.prefix(2000)), exitCode: result.exitCode, failure: result.failure))
        }
        let extra: [(String, Language, String, String)] = [
            ("C99 compound literal", .c99, "#include <stdio.h>\nstruct P { int x,y; }; int main(void) { struct P p=(struct P){4,5}; printf(\"%d\\n\",p.x+p.y); }", "9\n"),
            ("C99 floating point", .c99, "#include <stdio.h>\n#include <math.h>\nint main(void) { printf(\"%.2f %d %d\\n\",sqrt(2.25),isinf(INFINITY)!=0,isnan(NAN)!=0); }", "1.50 1 1\n"),
            ("C99 heap and sizeof", .c99, "#include <stdio.h>\n#include <stdlib.h>\nint main(void) { int *p=malloc(3*sizeof *p); if(!p)return 2; p[2]=42; printf(\"%zu %zu %d\\n\",sizeof(int),sizeof(long),p[2]); free(p); }", "4 4 42\n"),
            ("C++11 overloads", .cpp11, "#include <cstdio>\nint f(int){return 1;} int f(double){return 2;} int main(){static_assert(sizeof(int)==4,\"ABI\"); constexpr int n=3; std::printf(\"%d %d %d\\n\",f(1),f(1.0),n);}", "1 2 3\n"),
            ("C++11 RAII", .cpp11, "#include <cstdio>\nint n=0; struct X{~X(){++n;}}; int main(){{X x;} std::printf(\"%d\\n\",n);}", "1\n"),
            ("C99 EOF", .c99, "#include <stdio.h>\nint main(void) {printf(\"%d\\n\",getchar()==EOF);}", "1\n"),
            ("Putchar negative", .c99, "#include <stdio.h>\nint main(void){printf(\"%d\\n\",putchar(-1)==255);}", "\u{fffd}1\n")
        ]
        for (name, language, source, expected) in extra {
            let result = await compiler.run(source: source, language: language)
            results.append(.init(name: name, passed: result.succeeded && result.output == expected, output: result.output, exitCode: result.exitCode, failure: result.failure))
        }
        let cancelled = Cancellation(); cancelled.cancel()
        let stop = await compiler.run(source: "int main(void){return 0;}", language: .c99, cancellation: cancelled)
        results.append(.init(name: "Cancel before compile", passed: stop.failure == "Stopped.", output: stop.output, exitCode: stop.exitCode, failure: stop.failure))
        let again = await compiler.run(source: "#include <stdio.h>\nint main(void){puts(\"fresh run\");}", language: .c99)
        results.append(.init(name: "Repeat after traps", passed: again.succeeded && again.output == "fresh run\n", output: again.output, exitCode: again.exitCode, failure: again.failure))
        return results
    }
}
