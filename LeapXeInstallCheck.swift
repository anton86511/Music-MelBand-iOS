import Foundation

@main
enum LeapXeInstallCheck {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        precondition(arguments.count == 3)
        try LeapXeInstaller.assemble(checkpoint: arguments[0], template: arguments[1], into: arguments[2])
        print("Native Leap Xe installation passed both model SHA-256 checks.")
    }
}
