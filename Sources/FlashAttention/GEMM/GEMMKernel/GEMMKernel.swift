//
//  GEMMKernel.swift
//  FlashAttention
//
//  Created by Philip Turner on 6/21/24.
//

import protocol Metal.MTLLibrary

public struct GEMMKernel {
  // Categorical attributes for each operand.
  var memoryPrecisions: (
    A: GEMMOperandPrecision, B: GEMMOperandPrecision, C: GEMMOperandPrecision)
  var preferAsyncLoad: Bool
  var preferAsyncStore: Bool
  var registerPrecisions: (
    A: GEMMOperandPrecision, B: GEMMOperandPrecision, C: GEMMOperandPrecision)
  var transposeState: (A: Bool, B: Bool)
  
  // Layout of the data in registers and threadgroup memory.
  public var blockDimensions: (M: UInt16, N: UInt16, K: UInt16)
  var leadingBlockDimensions: (A: UInt16, B: UInt16, C: UInt16)
  var splits: (M: UInt16, N: UInt16)
  public var threadgroupMemoryAllocation: UInt16
  
  public init(descriptor: GEMMKernelDescriptor) {
    guard let blockDimensions = descriptor.blockDimensions,
          let memoryPrecisions = descriptor.memoryPrecisions,
          let preferAsyncStore = descriptor.preferAsyncStore,
          let registerPrecisions = descriptor.registerPrecisions,
          let splits = descriptor.splits,
          let transposeState = descriptor.transposeState else {
      fatalError("Descriptor was incomplete: \(descriptor)")
    }
    
    self.memoryPrecisions = memoryPrecisions
    self.preferAsyncLoad = descriptor.preferAsyncLoad
    self.preferAsyncStore = preferAsyncStore
    self.registerPrecisions = registerPrecisions
    
    self.blockDimensions = blockDimensions
    self.splits = splits
    self.transposeState = transposeState
    
    // Validate the correctness of register precisions.
    func checkOperandPair(
      memory: GEMMOperandPrecision,
      register: GEMMOperandPrecision
    ) -> Bool {
      // Truth table:
      //
      // memory | register | valid |
      // ------ | -------- | ----- |
      // FP32   | FP32     | yes   |
      // FP32   | FP16     | no    |
      // FP32   | BF16     | no    |
      // FP16   | FP32     | yes   |
      // FP16   | FP16     | yes   |
      // FP16   | BF16     | no    |
      // BF16   | FP32     | yes   |
      // BF16   | FP16     | no    |
      // BF16   | BF16     | yes   |
      //
      // Optimized form of the logic:
      //
      // If the register precision matches the memory precision,
      //   return true
      // If the register precision equals FP32,
      //   return true
      // Otherwise,
      //   return false
      //
      // The logic statements will change if you introduce custom quantized
      // formats. The truth table will grow exponentially. You'll need to add
      // more restrictions on accepted pairs to overcome the combinatorial
      // explosion.
      if register == memory {
        return true
      } else if register == .FP32 {
        return true
      } else {
        return false
      }
    }
    
    guard checkOperandPair(
      memory: memoryPrecisions.A, register: registerPrecisions.A) else {
      fatalError("Operand A had an invalid register precision.")
    }
    guard checkOperandPair(
      memory: memoryPrecisions.B, register: registerPrecisions.B) else {
      fatalError("Operand B had an invalid register precision.")
    }
    guard checkOperandPair(
      memory: memoryPrecisions.C, register: registerPrecisions.C) else {
      fatalError("Operand C had an invalid register precision.")
    }
    if registerPrecisions.C == .BF16 {
      // BF16 has too few mantissa bits to be an accurate accumulator. In
      // addition, switching from FP32 accumulator to BF16 accumulator slows
      // down execution speed on both M1/M2 and M3+.
      fatalError("BF16 cannot be used as the register precision for C.")
    }
    
    // Retrieve the "padded" block dimensions, otherwise compute analytically
    // from the true block dimensions.
    func chooseLeadingBlockDimension(
      specifiedLeading: UInt16?,
      transposeState: Bool,
      untransposedRows: UInt16,
      untransposedColumns: UInt16
    ) -> UInt16 {
      var expectedLeading: UInt16
      if transposeState {
        expectedLeading = untransposedRows
      } else {
        expectedLeading = untransposedColumns
      }
      
      var actualLeading: UInt16
      if let specifiedLeading {
        guard specifiedLeading >= expectedLeading else {
          fatalError("Leading block dimension was too small.")
        }
        actualLeading = specifiedLeading
      } else {
        actualLeading = expectedLeading
      }
      
      return actualLeading
    }
    
    // Pick the leading block dimensions.
    leadingBlockDimensions = (.zero, .zero, .zero)
    leadingBlockDimensions.A = chooseLeadingBlockDimension(
      specifiedLeading: descriptor.leadingBlockDimensions?.A,
      transposeState: transposeState.A,
      untransposedRows: blockDimensions.M,
      untransposedColumns: blockDimensions.K)
    leadingBlockDimensions.B = chooseLeadingBlockDimension(
      specifiedLeading: descriptor.leadingBlockDimensions?.B,
      transposeState: transposeState.B,
      untransposedRows: blockDimensions.K,
      untransposedColumns: blockDimensions.N)
    leadingBlockDimensions.C = chooseLeadingBlockDimension(
      specifiedLeading: descriptor.leadingBlockDimensions?.C,
      transposeState: false,
      untransposedRows: blockDimensions.M,
      untransposedColumns: blockDimensions.N)
    
    // Pick the threadgroup memory allocation size.
    threadgroupMemoryAllocation = .zero
    threadgroupMemoryAllocation = createThreadgroupMemoryAllocation()
  }
}

extension GEMMKernel {
  func memoryName(_ operand: String) -> String {
    switch operand {
    case "A": return memoryPrecisions.A.name
    case "B": return memoryPrecisions.B.name
    case "C": return memoryPrecisions.C.name
    default:
      fatalError("Unrecognized operand.")
    }
  }
  
  func registerName(_ operand: String) -> String {
    switch operand {
    case "A": return registerPrecisions.A.name
    case "B": return registerPrecisions.B.name
    case "C": return registerPrecisions.C.name
    default:
      fatalError("Unrecognized operand.")
    }
  }
  
  func transposed(_ operand: String) -> Bool {
    switch operand {
    case "A": return transposeState.A
    case "B": return transposeState.B
    case "C": return false
    default: fatalError("Unrecognized operand.")
    }
  }
}

extension GEMMKernel {
  func leadingDimension(_ operand: String) -> String {
    return "\(operand)_leading_dimension"
  }
  
  func leadingBlockDimension(_ operand: String) -> UInt16 {
    switch operand {
    case "A": return leadingBlockDimensions.A
    case "B": return leadingBlockDimensions.B
    case "C": return leadingBlockDimensions.C
    default: fatalError("Unrecognized operand.")
    }
  }
  
  func trailingBlockDimension(_ operand: String) -> UInt16 {
    func chooseTrailingBlockDimension(
      _ transposeState: Bool,
      _ untransposedRows: UInt16,
      _ untransposedColumns: UInt16
    ) -> UInt16 {
      if transposeState {
        return untransposedColumns
      } else {
        return untransposedRows
      }
    }
    
    switch operand {
    case "A":
      return chooseTrailingBlockDimension(
        transposed("A"), blockDimensions.M, blockDimensions.K)
    case "B":
      return chooseTrailingBlockDimension(
        transposed("B"), blockDimensions.K, blockDimensions.N)
    case "C":
      return chooseTrailingBlockDimension(
        transposed("C"), blockDimensions.M, blockDimensions.N)
    default:
      fatalError("Unrecognized operand.")
    }
  }
  
  func blockBytes(_ operand: String) -> UInt16 {
    var output: UInt16 = 1
    output *= leadingBlockDimension(operand)
    output *= trailingBlockDimension(operand)
    
    var memoryPrecision: GEMMOperandPrecision
    switch operand {
    case "A":
      memoryPrecision = memoryPrecisions.A
    case "B":
      memoryPrecision = memoryPrecisions.B
    case "C":
      memoryPrecision = memoryPrecisions.C
    default:
      fatalError("Unrecognized operand.")
    }
    output *= UInt16(memoryPrecision.size)
    return output
  }
}

extension GEMMKernel {
  var registerM: UInt16 {
    blockDimensions.M / splits.M
  }
  
  var registerN: UInt16 {
    blockDimensions.N / splits.N
  }
  
  public var threadgroupSize: UInt16 {
    32 * splits.M * splits.N
  }
  
  private func createThreadgroupMemoryAllocation() -> UInt16 {
    let blockBytesA = self.blockBytes("A")
    let blockBytesB = self.blockBytes("B")
    let blockBytesC = self.blockBytes("C")
    return max(blockBytesA + blockBytesB, blockBytesC)
  }
}
