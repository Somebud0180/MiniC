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
    std::cout << twice(*p) << '\n';
}