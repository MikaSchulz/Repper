import Foundation

/// One sample of what the watch can actually report about its own motion.
///
/// The attitude is the part the phone recording does not have: without the orientation of
/// the device there is no way to rotate the acceleration into a fixed frame, and without
/// that the direction of a movement at the wrist cannot be recovered.
struct WristSample {
    var t: Double                       // seconds since the start of the recording
    var acc: (x: Double, y: Double, z: Double)      // userAcceleration, gravity removed [m/s^2]
    var quat: (w: Double, x: Double, y: Double, z: Double)   // attitude, device -> reference
    var rot: (x: Double, y: Double, z: Double)      // rotationRate [rad/s]
}

enum WristRecordingFile {

    static let header = "t,ax,ay,az,qw,qx,qy,qz,rx,ry,rz"

    /// Metadata keys travelling with the file to the phone.
    enum Key {
        static let kind = "kind"            // "wrist"
        static let trueReps = "trueReps"
        static let machine = "machine"
        static let duration = "duration"
        static let sampleCount = "sampleCount"
    }

    static func csv(_ samples: [WristSample]) -> String {
        var text = header + "\n"
        text.reserveCapacity(samples.count * 80)
        for s in samples {
            text += String(format: "%.4f,%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f\n",
                           s.t, s.acc.x, s.acc.y, s.acc.z,
                           s.quat.w, s.quat.x, s.quat.y, s.quat.z,
                           s.rot.x, s.rot.y, s.rot.z)
        }
        return text
    }

    /// Machines to pick from after a recording — short enough to tap through on a watch.
    static let machines = ["Chest Press", "Lat Pulldown", "Leg Press", "Leg Curl",
                           "Leg Extension", "Rudern", "Butterfly", "Curl", "Sonstige"]
}
