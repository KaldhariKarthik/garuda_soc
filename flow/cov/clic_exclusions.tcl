# =============================================================================
# clic_exclusions.tcl - coverage waivers for block 10, the CLIC.
#
# Applied in IMC after loading the merged CLIC run:
#     imc -load sim/uvm_clic/cov_work/scope/all -init flow/cov/clic_exclusions.tcl
# or typed at the IMC prompt. Every line has its reason. Sign-off criterion 3
# (flow/0_signoff_criteria.md): code coverage 100% after the waivers below.
#
# One reason covers almost everything here: IDs 0, 7 and 24 to 31 have no
# interrupt source (garuda_system.yaml clic.map), so their enable bits are
# hardwired to 0 by GARUDA_CLIC_ID_MASK and can never toggle. CLIC [N-6.2],
# [N-6.3] as amended by INT-2 and INT-3; checked by property a_reserved_ids.
# =============================================================================
# 2026-11-20 (D-40): 22 exclusions removed that IMC reported as matching nothing (*W,NOMATCH):
# the code they named was renamed or removed in F4 / D-39. cov_chart now fails on any such line.
exclude -inst clic_top -toggle ie\[0\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[7\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[23\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[24\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[25\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[26\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[27\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[28\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[29\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[30\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top -toggle ie\[31\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[0\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[7\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[23\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[24\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[25\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[26\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[27\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[28\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[29\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[30\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_o\[31\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[0\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[7\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[23\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[24\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[25\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[26\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[27\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[28\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[29\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[30\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_apb -toggle ie_q\[31\] -comment "enable bit of an ID with no source: hardwired 0 by GARUDA_CLIC_ID_MASK, checked by a_reserved_ids"
exclude -inst clic_top.u_sel -toggle cand_i\[0\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[7\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[23\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[24\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[25\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[26\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[27\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[28\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[29\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[30\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top.u_sel -toggle cand_i\[31\] -comment "candidate bit of an ID with no source: its enable is hardwired 0, so enable AND pending is always 0"
exclude -inst clic_top -toggle pready_o -comment "constant 1: the block is zero-wait by specification (CLIC section 5), checked by a_pready"
exclude -inst clic_top.u_apb -toggle pready_o -comment "constant 1: the block is zero-wait by specification (CLIC section 5), checked by a_pready"
# The two per-ID selection properties can only trigger for an ID that can be a
# candidate. For the 11 IDs with no source the antecedent is unreachable.

# 2026-11-20 (D-40): the candidate vector is clic_top.cand since F4 (was u_sel.cand_i)
exclude -inst clic_top -toggle cand\[0\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[7\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[24\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[25\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[26\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[27\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[28\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[29\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[30\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
exclude -inst clic_top -toggle cand\[31\] -comment "candidate bit of an ID with no source: its enable is hardwired 0 by IE_MASK (00FF_FF7E: IDs 0, 7 and 24-31), so cand = pending & enable is 0"
