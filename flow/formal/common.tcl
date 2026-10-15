# common.tcl - shared by the *_fpv.tcl scripts
#   list_props <file>: every assertion and cover with its status, one line each.
#   A proof is vacuous when the trigger of its assertion can never happen, so the
#   ":precondition1" covers must all be "covered" and are listed first.
proc list_props {file} {
    set fh [open $file w]
    foreach p [get_property_list -include {type {assert cover}}] {
        puts $fh [format "%-12s %-7s %s" [get_property_info $p -list status] [get_property_info $p -list type] $p]
    }
    close $fh
}
