import AiGoKit
import Darwin
import Foundation

@main
struct AiGoSelfTestsMain {
    static func main() async {
        let report = await AiGoSelfTestSuite.run()
        if report.isSuccessful {
            print("AiGo self-tests: \(report.passed) passed, 0 failed")
            return
        }

        print("AiGo self-tests: \(report.passed) passed, \(report.failures.count) failed")
        for failure in report.failures {
            print("FAIL: \(failure)")
        }
        exit(EXIT_FAILURE)
    }
}
