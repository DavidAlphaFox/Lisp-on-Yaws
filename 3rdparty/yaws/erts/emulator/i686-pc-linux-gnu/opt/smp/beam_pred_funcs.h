/*
 *  Warning: Do not edit this file.
 *  Auto-generated by 'beam_makeops'.
 */


case 0: RVAL = use_jump_tab(st, var[2], var+3); break;
case 1: RVAL = use_jump_tab(st, var[2], var+3); break;
case 2: RVAL = mixed_types(st, var[3], var+4); break;
case 3: RVAL = mixed_types(st, var[2], var+3); break;
case 4: RVAL = fixed_size_values(st, var[2], var+3); break;
case 5: RVAL = fixed_size_values(st, var[2], var+3); break;
case 6: RVAL = floats_or_bignums(st, var[2], var+3); break;
case 7: RVAL = fixed_size_values(st, var[2], var+3); break;
case 8: RVAL = same_label(st, var[0], var[1]); break;
case 9: RVAL = same_label(st, var[0], var[4]); break;
case 10: RVAL = smp_mark_target_label(st, var[0]); break;
case 11: RVAL = smp_already_locked(st, var[0]); break;
case 12: RVAL = smp_already_locked(st, var[0]); break;
case 13: RVAL = smp(st); break;
case 14: RVAL = smp_already_locked(st, var[0]); break;
case 15: RVAL = succ(st, var[1], var[2]); break;
case 16: RVAL = succ(st, var[2], var[3]); break;
case 17: RVAL = succ(st, var[0], var[4]); break;
case 18: RVAL = succ(st, var[2], var[3]); break;
case 19: RVAL = succ2(st, var[0], var[4]); break;
case 20: RVAL = binary_too_big(st, var[1]); break;
case 21: RVAL = should_gen_heap_bin(st, var[1]); break;
case 22: RVAL = should_gen_heap_bin(st, var[1]); break;
case 23: RVAL = binary_too_big_bits(st, var[1]); break;
case 24: RVAL = no_fpe_signals(st); break;
case 25: RVAL = no_fpe_signals(st); break;
case 26: RVAL = negation_is_small(st, var[2]); break;

