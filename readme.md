nRF Scripts
===========

This is a collection of shell functions that make it easier to work with
nRF SoC SDK.

Setup
=====
Just source the `nrf-scripts.sh` into your shell:

   source nrf-scripts.sh

Some of the functions use the [pick](https://github.com/calleerlandsson/pick)
tool to provide a selection dialog in a case when there is more then one 
DK connected to your PC. 

Functions
=========

`nrf_make [args]`
Build using selected defaults. Instead of going into the folder where
the makefile is you can run `nrf_make` directly from the example folder.
The function will find the makefile, cd to the location and run `make`.

Additional arguments are passed to `make` command.

`nrf_flash [hex]`
Flash using selected defaults. If hex file isn't specified the function
will try to find one in subfolders.

`nrf_sign`
Sing hexfile and generate a package. The function will try to find a
hex file.

`nrf_dfu_gen_settings`
Generate DFU Bootloader settings file.

`nrf_dfu`
Perform DFU over BLE.

`nrf_rtt`
Starts JLinkExe in the background and telnet in the forground. Exit by
opening telent prompt (Ctrl+]) and typing 'q'.

