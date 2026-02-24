/*
 * VexRiscv generation for PocketQuake
 *
 * RV32IMAF with Wishbone bus, no MMU, no debug.
 *   I-cache: 16KB (2-way, 32B lines)
 *   D-cache: 128KB (2-way, 32B lines)
 *
 * Usage:
 *   1. Clone VexRiscv: git clone https://github.com/SpinalHDL/VexRiscv.git
 *   2. Copy this file into VexRiscv/src/main/scala/vexriscv/demo/
 *   3. cd VexRiscv && sbt "runMain vexriscv.demo.GenPocketQuake"
 *   4. Copy VexRiscv.v to VexRiscv_Full.v
 */

package vexriscv.demo

import vexriscv.ip.{DataCacheConfig, InstructionCacheConfig}
import vexriscv.ip.fpu.FpuParameter
import vexriscv.plugin._
import vexriscv.{VexRiscv, VexRiscvConfig, plugin}
import spinal.core._
import spinal.lib._

object GenPocketQuake extends App {

  def cpuConfig = VexRiscvConfig(
    plugins = List(
      new IBusCachedPlugin(
        resetVector = null,           // creates externalResetVector input
        compressedGen = false,        // RVC disabled for higher Fmax
        injectorStage = true,         // extra pipeline stage for timing
        relaxedPcCalculation = true,
        prediction = DYNAMIC,
        config = InstructionCacheConfig(
          cacheSize = 16384,          // 16 KB
          bytePerLine = 32,
          wayCount = 2,
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchIllegalAccess = true,
          catchAccessFault = true,
          asyncTagMemory = false,
          twoCycleRam = true,
          twoCycleCache = true
        )
      ),
      new DBusCachedPlugin(
        config = new DataCacheConfig(
          cacheSize = 131072,         // 128 KB
          bytePerLine = 32,
          wayCount = 2,               // 2-way associative
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchAccessError = true,
          catchIllegal = true,
          catchUnaligned = true
        ),
        dBusCmdMasterPipe = true      // required for Wishbone
      ),
      // Cacheable: 0x1X (SDRAM), 0x30-0x37 (PSRAM)
      // Uncacheable: 0x0X (BRAM — already fast), 0x38-0x3F (SRAM — HW writes bypass cache), all IO
      // Note: DMA coherency for dataslot_read handled by fence + SDRAM_UNCACHED() alias
      new StaticMemoryTranslatorPlugin(
        ioRange = addr => addr(31 downto 28) =/= 0x1 &&
                          !(addr(31 downto 28) === 0x3 && !addr(27))
      ),
      new DecoderSimplePlugin(
        catchIllegalInstruction = true
      ),
      new RegFilePlugin(
        regFileReadyKind = plugin.SYNC,
        zeroBoot = false
      ),
      new IntAluPlugin,
      new SrcPlugin(
        separatedAddSub = false,
        executeInsertion = true
      ),
      new FullBarrelShifterPlugin,
      new MulPlugin,
      new DivPlugin,
      new HazardSimplePlugin(
        bypassExecute = true,
        bypassMemory = true,
        bypassWriteBack = true,
        bypassWriteBackBuffer = true,
        pessimisticUseSrc = false,
        pessimisticWriteRegFile = false,
        pessimisticAddressMatch = false
      ),
      new BranchPlugin(
        earlyBranch = false,
        catchAddressMisaligned = true
      ),
      new CsrPlugin(CsrPluginConfig.small(mtvecInit = 0x80000020l)),
      new FpuPlugin(
        externalFpu = false,
        simHalt = false,
        p = FpuParameter(
          withDouble = false          // single-precision only (F extension)
        )
      ),
      new YamlPlugin("cpu0.yaml")
    )
  )

  val report = SpinalVerilog {
    val config = cpuConfig
    val cpu = new VexRiscv(config)
    cpu.setDefinitionName("VexRiscv")

    // Convert internal buses to Wishbone
    cpu.rework {
      for (plugin <- config.plugins) plugin match {
        case plugin: IBusCachedPlugin => {
          plugin.iBus.setAsDirectionLess()
          master(plugin.iBus.toWishbone()).setName("iBusWishbone")
        }
        case plugin: DBusCachedPlugin => {
          plugin.dBus.setAsDirectionLess()
          master(plugin.dBus.toWishbone()).setName("dBusWishbone")
        }
        case _ =>
      }
    }
    cpu
  }
}
