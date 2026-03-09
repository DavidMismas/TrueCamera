import Foundation
import CoreVideo
import CoreGraphics

let pixelBuffer: CVPixelBuffer? = nil
if let buffer = pixelBuffer {
    let colorSpace = CVImageBufferGetColorSpace(buffer)
    print(colorSpace)
}
