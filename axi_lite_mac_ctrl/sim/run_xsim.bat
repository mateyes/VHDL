@echo off
rem ===========================================================================
rem run_xsim.bat : compile and run the AXI4-Lite MAC control testbench
rem Tool         : Vivado Simulator (xvhdl / xelab / xsim)
rem Usage        : run this script from Windows command prompt or double-click
rem Requirement  : xvhdl/xelab/xsim in PATH, or set XILINX_VIVADO to the
rem                Vivado installation directory before running.
rem ===========================================================================
setlocal
if defined XILINX_VIVADO call "%XILINX_VIVADO%\settings64.bat" >nul 2>&1
cd /d "%~dp0.."

if exist xsim.dir rmdir /s /q xsim.dir

echo [1/4] compile design ...
call xvhdl --2008 src\axi_lite_mac_ctrl.vhd
if errorlevel 1 goto :err

echo [2/4] compile testbench ...
call xvhdl --2008 sim\tb_axi_lite_mac_ctrl.vhd
if errorlevel 1 goto :err

echo [3/4] elaborate ...
call xelab --debug typical --relax tb_axi_lite_mac_ctrl -s tb_sim
if errorlevel 1 goto :err

echo [4/4] run simulation ...
call xsim tb_sim -runall
if errorlevel 1 goto :err

echo.
echo [OK] simulation completed successfully.
goto :eof

:err
echo.
echo [ERROR] compile / elaborate / simulate failed.
exit /b 1
