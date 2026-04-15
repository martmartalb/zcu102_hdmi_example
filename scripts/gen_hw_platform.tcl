# ============================================
# Vivado build script (synth + impl + XSA)
# ============================================

# Default values
set origin_dir "."
set proj_name "vivado_project"
set jobs 30

# --------------------------------------------
# Parse arguments
# --------------------------------------------
if { $::argc > 0 } {
  for {set i 0} {$i < $::argc} {incr i} {
    set option [string trim [lindex $::argv $i]]
    switch -regexp -- $option {
      "--origin_dir"   { incr i; set origin_dir [lindex $::argv $i] }
      "--project_name" { incr i; set proj_name [lindex $::argv $i] }
      "--platform_name" { incr i; set platform_name [lindex $::argv $i] }
      "--jobs"         { incr i; set jobs [lindex $::argv $i] }
      default {
        if { [regexp {^-} $option] } {
          puts "ERROR: Unknown option '$option'"
          return 1
        }
      }
    }
  }
}

# Normalize paths
set proj_dir  [file normalize "$origin_dir/$proj_name"]
set proj_file "$proj_dir/$proj_name.xpr"

puts "==> Opening project: $proj_file"

# --------------------------------------------
# Open existing project
# --------------------------------------------
if { ![file exists $proj_file] } {
  puts "ERROR: Project file not found: $proj_file"
  return 1
}

open_project $proj_file

# --------------------------------------------
# Reset runs
# --------------------------------------------
puts "==> Resetting runs..."
if { [get_runs synth_1] ne "" } {
    reset_run synth_1
}
if { [get_runs impl_1] ne "" } {
    reset_run impl_1
}

# --------------------------------------------
# Launch synthesis
# --------------------------------------------
puts "==> Running synthesis..."

# Increase the max loop limit (necessary for ROM with image)
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter max_loop_limit 1200000"

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

# --------------------------------------------
# Launch implementation + bitstream
# --------------------------------------------
puts "==> Running implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

# --------------------------------------------
# Generate hardware platform (XSA)
# --------------------------------------------
set xsa_file "$proj_dir/$platform_name.xsa"

puts "==> Generating XSA: $xsa_file"

write_hw_platform -fixed -include_bit -force -file $xsa_file
validate_hw_platform -verbose $xsa_file

puts "==> Build completed successfully!"