// SPDX-License-Identifier: GPL-3.0-only
// Deterministic synthetic ISO BMFF fixtures; no external media or encoder services.
import Foundation
import CryptoKit

func be(_ n: UInt32) -> Data { var n = n.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
func short(_ n: UInt16) -> Data { var n = n.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
func join(_ parts: Data...) -> Data { parts.reduce(Data(), +) }
func zeros(_ n: Int) -> Data { Data(repeating: 0, count: n) }
func box(_ type: String, _ data: Data) -> Data {
    precondition(type.utf8.count == 4)
    return be(UInt32(data.count + 8)) + Data(type.utf8) + data
}
func full(_ type: String, _ data: Data, flags: UInt32 = 0) -> Data { box(type, be(flags) + data) }
struct Bits {
    var bytes = Data(); var byte: UInt8 = 0; var used = 0
    mutating func bit(_ b: Int) { byte = (byte << 1) | UInt8(b & 1); used += 1; if used == 8 { bytes.append(byte); byte = 0; used = 0 } }
    mutating func uint(_ n: Int, _ width: Int) { for i in (0..<width).reversed() { bit(n >> i) } }
    mutating func ue(_ n: Int) { let v = n+1; let width = Int.bitWidth-v.leadingZeroBitCount; for _ in 1..<width { bit(0) }; uint(v,width) }
    mutating func align() { while used != 0 { bit(0) } }
    mutating func trailing() { bit(1); align() }
}
func nal(_ header: UInt8, _ rbsp: Data) -> Data {
    var result = Data([header]); var zeroCount = 0
    for b in rbsp {
        if zeroCount == 2 && b <= 3 { result.append(3); zeroCount = 0 }
        result.append(b); zeroCount = b == 0 ? zeroCount+1 : 0
    }
    return result
}
// H.264 Baseline, 160x96, all IDR I_PCM macroblocks, 12 fps, 36 frames.
// I_PCM stores our YCbCr samples directly; no platform-dependent encoder.
var sps = Bits()
sps.uint(66,8); sps.uint(0xc0,8); sps.uint(31,8); sps.ue(0)
sps.ue(0); sps.ue(2); sps.ue(0); sps.bit(0); sps.ue(9); sps.ue(5)
sps.bit(1); sps.bit(1); sps.bit(0); sps.bit(0); sps.trailing()
let sequence = nal(0x67,sps.bytes)
var pps = Bits()
pps.ue(0); pps.ue(0); pps.bit(0); pps.bit(0); pps.ue(0)
pps.ue(0); pps.ue(0); pps.bit(0); pps.uint(0,2)
pps.ue(0); pps.ue(0); pps.ue(0); pps.bit(0); pps.bit(0); pps.bit(0); pps.trailing()
let picture = nal(0x68,pps.bytes)
var videoSamples = [Data]()
for frame in 0..<36 {
    var slice = Bits()
    slice.ue(0); slice.ue(2); slice.ue(0); slice.uint(0,4); slice.ue(frame % 2)
    slice.bit(0); slice.bit(0); slice.ue(0)
    for my in 0..<6 { for mx in 0..<10 {
        slice.ue(25); slice.align()
        for y in 0..<16 { for x in 0..<16 {
            slice.uint(32 + ((mx*16+x + my*16+y + frame*5) % 192),8)
        }}
        for _ in 0..<64 { slice.uint(80 + (frame % 12)*4,8) }
        for _ in 0..<64 { slice.uint(176 - (frame % 12)*4,8) }
    }}
    slice.trailing()
    let n = nal(0x65,slice.bytes)
    videoSamples.append(be(UInt32(n.count)) + n)
}
let avcc = Data([1,66,0xc0,31,0xff,0xe1]) + short(UInt16(sequence.count)) + sequence
    + Data([1]) + short(UInt16(picture.count)) + picture
let videoEntry = box("avc1", join(zeros(6), short(1), zeros(16), short(160), short(96),
    be(0x00480000), be(0x00480000), zeros(4), short(1), zeros(32),
    short(24), short(0xffff), box("avcC",avcc)))

// ALAC mono 16-bit, one second at 44100 Hz. Uncompressed ALAC packets.
// Integer triangle wave, period 100 samples, amplitude <= 6000; no libm variation.
var audioSamples = [Data](); var audioDurations = [Int]()
for start in stride(from: 0, to: 44100, by: 4096) {
    let count = min(4096,44100-start)
    var packet = Bits()
    packet.uint(0,3); packet.uint(0,4); packet.uint(0,12)
    packet.bit(1); packet.uint(0,2); packet.bit(1); packet.uint(count,32)
    for i in start..<start+count {
        let phase = i % 100
        let sample = (phase < 50 ? phase : 100-phase)*240 - 6000
        packet.uint(Int(UInt16(bitPattern: Int16(sample))),16)
    }
    packet.uint(7,3); packet.align()
    audioSamples.append(packet.bytes); audioDurations.append(count)
}
let alacConfig = be(4096) + Data([0,16,40,10,14,1]) + short(255) + be(0) + be(0) + be(44100)
let audioEntry = box("alac", zeros(6) + short(1) + zeros(8) + short(1) + short(16)
    + zeros(4) + be(44100 << 16) + full("alac",alacConfig))

func pngChunk(_ name: String, _ bytes: Data) -> Data {
    let payload = Data(name.utf8) + bytes
    var crc: UInt32 = 0xffffffff
    for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
    return be(UInt32(bytes.count)) + payload + be(crc ^ 0xffffffff)
}
// Transparent black pixel, grayscale+alpha. Fixed-Huffman DEFLATE encodes
// three zero bytes (filter, gray, alpha); Adler32 0x00030001; computed CRCs.
let artwork = Data([137,80,78,71,13,10,26,10])
    + pngChunk("IHDR", be(1) + be(1) + Data([8,4,0,0,0]))
    + pngChunk("IDAT", Data([0x78,0x01,0x63,0x60,0x60,0x00,0x00,0x00,0x03,0x00,0x01]))
    + pngChunk("IEND",Data())
precondition(artwork.count == 68)
func tag(_ key: [UInt8], _ value: Data, _ type: UInt32) -> Data {
    let payload = box("data", be(type) + be(0) + value)
    return be(UInt32(payload.count+8)) + Data(key) + payload
}
let tags = tag([0xa9,110,97,109],Data("Fixture Title".utf8),1)
    + tag([0xa9,65,82,84],Data("Fixture Artist".utf8),1)
    + tag([0xa9,97,108,98],Data("Fixture Album".utf8),1)
    + tag([0xa9,108,121,114],Data("Line one\nLine two".utf8),1)
    + tag(Array("covr".utf8),artwork,14)
let metadata = box("udta",full("meta",full("hdlr",be(0)+Data("mdir".utf8)+zeros(12)+Data([0])) + box("ilst",tags)))
let matrix = be(0x10000)+be(0)+be(0)+be(0)+be(0x10000)+be(0)+be(0)+be(0)+be(0x40000000)
func movie(samples: [Data], durations: [Int], scale: Int, entry: Data, video: Bool) -> Data {
    let duration = durations.reduce(0,+)
    let ftyp = box("ftyp",Data((video ? "isom" : "M4A ").utf8)+be(0)+Data("isommp42".utf8))
    let mdat = box("mdat",samples.reduce(Data(),+))
    let mvhd = full("mvhd",zeros(8)+be(UInt32(scale))+be(UInt32(duration))+be(0x10000)+short(0x100)+zeros(10)+matrix+zeros(24)+be(2))
    let tkhd = full("tkhd",join(zeros(8),be(1),be(0),be(UInt32(duration)),zeros(8),short(0),short(0),short(video ? 0 : 0x100),short(0),matrix,be(video ? 160<<16 : 0),be(video ? 96<<16 : 0)),flags:3)
    let mdhd = full("mdhd",zeros(8)+be(UInt32(scale))+be(UInt32(duration))+short(0x55c4)+short(0))
    let hdlr = full("hdlr",be(0)+Data((video ? "vide" : "soun").utf8)+zeros(12)+Data("Synthetic\0".utf8))
    let header = video ? full("vmhd",zeros(8),flags:1) : full("smhd",zeros(4))
    let dinf = box("dinf",full("dref",be(1)+full("url ",Data(),flags:1)))
    let stsd = full("stsd",be(1)+entry)
    let stts = full("stts",be(UInt32(durations.count))+durations.reduce(Data()) { $0+be(1)+be(UInt32($1)) })
    let stsc = full("stsc",be(1)+be(1)+be(UInt32(samples.count))+be(1))
    let stsz = full("stsz",be(0)+be(UInt32(samples.count))+samples.reduce(Data()) { $0+be(UInt32($1.count)) })
    let stco = full("stco",be(1)+be(UInt32(ftyp.count+8)))
    let stbl = box("stbl",stsd+stts+stsc+stsz+stco)
    let mdia = box("mdia",mdhd+hdlr+box("minf",header+dinf+stbl))
    return ftyp+mdat+box("moov",mvhd+box("trak",tkhd+mdia)+(video ? Data() : metadata))
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("DrivePlayer.xcodeproj/project.pbxproj").path)
    && FileManager.default.fileExists(atPath: root.appendingPathComponent("tools/generate-fixtures.swift").path),
    "Run this generator only from the Vivi Player repository root")
for (path,data) in [
    ("DrivePlayer/Resources/phase0-test.mp4",movie(samples:videoSamples,durations:Array(repeating:1,count:36),scale:12,entry:videoEntry,video:true)),
    ("DrivePlayerTests/Resources/metadata-fixture.m4a",movie(samples:audioSamples,durations:audioDurations,scale:44100,entry:audioEntry,video:false))] {
    let destination = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:destination,options:.atomic)
    print("\(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())  \(path)")
}
