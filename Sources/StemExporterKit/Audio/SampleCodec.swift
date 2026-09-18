import Foundation

/// Raw little-endian PCM sample packing and unpacking.
///
/// Everything here works on byte pointers rather than arrays of samples: the export
/// engine moves tens of gigabytes through these, so there is no intermediate
/// boxing and no per-sample allocation.
public enum SampleCodec {

    // MARK: Integer PCM

    /// Read one little-endian signed integer sample of `bytes` width, sign-extended to Int32.
    @inline(__always)
    public static func readInt(_ p: UnsafeRawPointer, bytes: Int) -> Int32 {
        let b = p.assumingMemoryBound(to: UInt8.self)
        switch bytes {
        case 1:
            // 8-bit WAV is unsigned with a 128 bias.
            return Int32(b[0]) - 128
        case 2:
            return Int32(Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8)))
        case 3:
            var v = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16)
            if v & 0x0080_0000 != 0 { v |= 0xFF00_0000 }
            return Int32(bitPattern: v)
        case 4:
            let v = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Int32(bitPattern: v)
        default:
            return 0
        }
    }

    /// Write one little-endian signed integer sample of `bytes` width.
    @inline(__always)
    public static func writeInt(_ value: Int32, to p: UnsafeMutableRawPointer, bytes: Int) {
        let b = p.assumingMemoryBound(to: UInt8.self)
        switch bytes {
        case 1:
            b[0] = UInt8(truncatingIfNeeded: value &+ 128)
        case 2:
            let v = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
            b[0] = UInt8(truncatingIfNeeded: v)
            b[1] = UInt8(truncatingIfNeeded: v >> 8)
        case 3:
            let v = UInt32(bitPattern: value)
            b[0] = UInt8(truncatingIfNeeded: v)
            b[1] = UInt8(truncatingIfNeeded: v >> 8)
            b[2] = UInt8(truncatingIfNeeded: v >> 16)
        case 4:
            let v = UInt32(bitPattern: value)
            b[0] = UInt8(truncatingIfNeeded: v)
            b[1] = UInt8(truncatingIfNeeded: v >> 8)
            b[2] = UInt8(truncatingIfNeeded: v >> 16)
            b[3] = UInt8(truncatingIfNeeded: v >> 24)
        default:
            break
        }
    }

    // MARK: Float PCM

    @inline(__always)
    public static func readFloat(_ p: UnsafeRawPointer, bytes: Int) -> Double {
        let b = p.assumingMemoryBound(to: UInt8.self)
        if bytes == 8 {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(b[i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }
        var bits: UInt32 = 0
        for i in 0..<4 { bits |= UInt32(b[i]) << (8 * UInt32(i)) }
        return Double(Float(bitPattern: bits))
    }

    @inline(__always)
    public static func writeFloat(_ value: Double, to p: UnsafeMutableRawPointer, bytes: Int) {
        let b = p.assumingMemoryBound(to: UInt8.self)
        if bytes == 8 {
            let bits = value.bitPattern
            for i in 0..<8 { b[i] = UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i))) }
            return
        }
        let bits = Float(value).bitPattern
        for i in 0..<4 { b[i] = UInt8(truncatingIfNeeded: bits >> (8 * UInt32(i))) }
    }

    // MARK: Normalised access

    /// Read a sample as a normalised value in roughly -1.0...1.0, whatever the source depth.
    @inline(__always)
    public static func readNormalized(_ p: UnsafeRawPointer, format: AudioFormat) -> Double {
        if format.isFloat {
            return readFloat(p, bytes: format.bytesPerSample)
        }
        return Double(readInt(p, bytes: format.bytesPerSample)) / format.fullScale
    }

    /// Scale a sample by a linear factor and hard-limit it at full scale.
    ///
    /// Clamping (rather than letting the integer wrap) is what keeps a hot channel
    /// sounding like a clipped channel instead of a burst of noise.
    @inline(__always)
    public static func scaleAndClamp(_ value: Int32, gain: Double, maxMagnitude: Double) -> (value: Int32, clipped: Bool) {
        let scaled = (Double(value) * gain).rounded()
        if scaled >= maxMagnitude {
            return (Int32(maxMagnitude - 1), true)
        }
        if scaled <= -maxMagnitude {
            return (Int32(-maxMagnitude), true)
        }
        return (Int32(scaled), false)
    }

    /// Convert decibels to the linear multiplier used on each sample.
    @inline(__always)
    public static func linearGain(dB: Double) -> Double {
        dB == 0 ? 1.0 : pow(10.0, dB / 20.0)
    }
}
