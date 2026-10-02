import Foundation
public struct CompilerExample: Identifiable, Sendable {
    public let id: String
    public let language: Language
    public let source: String
    public let input: String
    public let expected: String?
    public init(id: String, language: Language, source: String, input: String = "", expected: String? = nil) {
        self.id = id; self.language = language; self.source = source; self.input = input; self.expected = expected
    }
    public static let all: [CompilerExample] = [
        .init(id: "C99 semantics", language: .c99, source: """
        #include <stdio.h>
        #include <stdint.h>
        #include <stdbool.h>
        struct Pair { int x, y; };
        int main(void) {
            struct Pair p = {.y = 7, .x = 3};
            int n = 4, a[n];
            for (int i = 0; i < n; ++i) a[i] = i * i;
            uint32_t u = UINT32_MAX;
            bool ok = (u + 1u == 0);
            printf("%d %d %d %zu %d\\n", p.x, p.y, a[3], sizeof(char), ok);
            return 0;
        }
        """, expected: "3 7 9 1 1\n"),
        .init(id: "C++11 library", language: .cpp11, source: """
        #include <iostream>
        #include <vector>
        #include <algorithm>
        #include <memory>
        template<class T> T twice(T x) { return x + x; }
        int main() {
            std::vector<int> values{3, 1, 2};
            std::sort(values.begin(), values.end());
            auto square = [](int x) { return x * x; };
            std::unique_ptr<int> p(new int(7));
            for (auto x : values) std::cout << square(x) << ' ';
            std::cout << twice(*p) << '\\n';
        }
        """, expected: "1 4 9 14\n"),
        .init(id: "Standard input", language: .c99, source: """
        #include <stdio.h>
        int main(void) {
            int a, b;
            if (scanf("%d %d", &a, &b) != 2) return 1;
            printf("sum = %d\\n", a + b);
            return 0;
        }
        """, input: "20 22\n", expected: "sum = 42\n"),
        .init(id: "Invalid source", language: .c99, source: "int main(void) { return missing_name; }"),
        .init(id: "Infinite loop", language: .c99, source: "int main(void) { volatile unsigned n = 0; for (;;) ++n; }"),
        .init(id: "Output limit", language: .c99, source: "#include <stdio.h>\n#include <string.h>\nint main(void) { char b[4096]; memset(b, 'x', sizeof b); for (;;) fwrite(b, 1, sizeof b, stdout); }"),
        .init(id: "C++ exceptions (unsupported)", language: .cpp11, source: "int main() { try { throw 7; } catch (int n) { return n; } }")
    ]
}
