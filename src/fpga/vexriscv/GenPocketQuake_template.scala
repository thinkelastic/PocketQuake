/*
 * VexRiscv generation for PocketQuake — TEMPLATE FOR SWEEP
 *
 * This file contains @@MARKER@@ placeholders replaced by vexriscv_sweep.sh.
 * Do not use directly — use GenPocketQuake.scala for manual builds.
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
        compressedGen = true,         // RVC enabled
        injectorStage = true,         // extra pipeline stage for timing
        relaxedPcCalculation = true,
        prediction = @@PREDICTION@@,
        config = InstructionCacheConfig(
          cacheSize = 16384,          // 16 KB
          bytePerLine = 32,
          wayCount = 1,               // direct-mapped for timing
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchIllegalAccess = true,
          catchAccessFault = true,
          asyncTagMemory = false,
          twoCycleRam = true,
          twoCycleCache = true,
          twoCycleRamInnerMux = true  // register way mux for timing
        )
      ),
      new DBusCachedPlugin(
        config = new DataCacheConfig(
          cacheSize = @@DCACHE_SIZE@@,
          bytePerLine = 32,
          wayCount = @@DCACHE_WAYS@@,
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchAccessError = true,
          catchIllegal = true,
          catchUnaligned = true,
          earlyDataMux = @@EARLY_DATA_MUX@@
        ),
        dBusCmdMasterPipe = true,     // required for Wishbone
        dBusCmdSlavePipe = @@DBUS_SLAVE_PIPE@@
      ),
      // Cacheable: 0x1X (SDRAM), 0x30-0x37 (PSRAM)
      // Uncacheable: 0x0X (BRAM — already fast), 0x38-0x3F (SRAM — HW writes bypass cache), all IO
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
        separatedAddSub = @@SEP_ADDSUB@@,
        executeInsertion = true
      ),
      new FullBarrelShifterPlugin,
      @@MUL_LINE@@,
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
      @@CSR_LINE@@,
      new FpuPlugin(
        externalFpu = false,
        simHalt = false,
        p = FpuParameter(
          @@FPU_PARAMS@@
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
