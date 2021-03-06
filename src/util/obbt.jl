export run_obbt_opf

"optimality-based bound tightening for Optimal Power Flow Relaxations"
function check_variables(pm::GenericPowerModel)
    try
        vm = var(pm, :vm)
    catch err
        (isa(error, KeyError)) && (error(LOGGER, "OBBT is not supported for models without explicit voltage magnitude variables"))
    end

    try
        td = var(pm, :td)
    catch err
        (isa(error, KeyError)) && (error(LOGGER, "OBBT is not supported for models without explicit voltage angle difference variables"))
    end
end

function check_obbt_options(ub::Float64, rel_gap::Float64, ub_constraint::Bool)
    if ub_constraint && isinf(ub)
        error(LOGGER, "the option upper_bound_constraint cannot be set to true without specifying an upper bound")
    end

    if !isinf(rel_gap) && isinf(ub)
        error(LOGGER, "rel_gap_tol is specified without providing an upper bound")
    end
end

function constraint_obj_bound(pm::GenericPowerModel, bound)
    model = PowerModels.check_cost_models(pm)
    if model != 2
        error("Only cost models of type 2 is supported at this time, given cost model type $(model)")
    end

    PowerModels.check_polynomial_cost_models(pm)

    from_idx = Dict(arc[1] => arc for arc in ref(pm, :arcs_from_dc))

    @constraint(pm.model,
            sum(
                gen["cost"][1]*var(pm, :pg, i)^2 +
                gen["cost"][2]*var(pm, :pg, i) +
                gen["cost"][3]
            for (i,gen) in ref(pm, :gen)) +
            sum(
                dcline["cost"][1]*var(pm,:p_dc, from_idx[i])^2 +
                dcline["cost"][2]*var(pm, :p_dc, from_idx[i])  +
                dcline["cost"][3]
            for (i,dcline) in ref(pm, :dcline))
            <= bound
    )
end

function create_modifications(pm::GenericPowerModel,
    vm_lb::Dict{Any,Float64}, vm_ub::Dict{Any,Float64},
    td_lb::Dict{Any,Float64}, td_ub::Dict{Any,Float64})

    modifications = Dict{String,Any}()

    modifications["per_unit"] = true
    modifications["bus"] = Dict{String,Any}()
    modifications["branch"] = Dict{String,Any}()

    for bus in ids(pm, :bus)
        index = string(ref(pm, :bus, bus, "index"))
        modifications["bus"][index] = Dict{String,Any}( "vmin" => vm_lb[bus], "vmax" => vm_ub[bus] )
    end

    for branch in ids(pm, :branch)
        index = string(ref(pm, :branch, branch, "index"))
        f_bus = ref(pm, :branch, branch, "f_bus")
        t_bus = ref(pm, :branch, branch, "t_bus")
        bp = (f_bus, t_bus)
        modifications["branch"][index] = Dict{String,Any}( "angmin" => td_lb[bp], "angmax" => td_ub[bp] )
    end

    return modifications
end


function run_obbt_opf(file::String, solver; kwargs...)
    data = PowerModels.parse_file(file)
    return run_obbt_opf(data, solver; kwargs...)
end

function run_obbt_opf(data::Dict{String,Any}, solver;
    model_constructor = QCWRTriPowerModel,
    max_iter = 100,
    time_limit = 3600.0,
    upper_bound = Inf,
    upper_bound_constraint = false,
    rel_gap_tol = Inf,
    min_bound_width = 1e-2,
    improvement_tol = 1e-3,
    precision = 4,
    termination = :avg,
    kwargs...)

    info(LOGGER, "maximum OBBT iterations set to default value of $max_iter")
    info(LOGGER, "maximum time limit for OBBT set to default value of $time_limit seconds")

    model_relaxation = build_generic_model(data, model_constructor, PowerModels.post_opf)
    (ismultinetwork(model_relaxation)) && (error(LOGGER, "OBBT is not supported for multi-networks"))
    (ismulticonductor(model_relaxation)) && (error(LOGGER, "OBBT is not supported for multi-phase networks"))

    # check for model_constructor compatability with OBBT
    check_variables(model_relaxation)

    # check for other keyword argument consistencies
    check_obbt_options(upper_bound, rel_gap_tol, upper_bound_constraint)

    # check termination norm criteria for obbt
    (termination != :avg && termination != :max) && (error(LOGGER, "OBBT termination criteria can only be :max or :avg"))

    # pass status
    status_pass = [:LocalOptimal, :Optimal]

    # compute initial relative gap between relaxation objective and upper_bound
    result_relaxation = solve_generic_model(model_relaxation, solver)
    current_relaxation_objective = result_relaxation["objective"]
    if upper_bound < current_relaxation_objective
        error(LOGGER, "the upper bound provided to OBBT is not a valid ACOPF upper bound")
    end
    if !(result_relaxation["status"] in status_pass)
        warn(LOGGER, "initial relaxation solve status is $(result_relaxation["status"])")
        if result_relaxation["status"] == :SubOptimal
            warn(LOGGER, "continuing with the bound-tightening algorithm")
        end
    end
    current_rel_gap = Inf
    if !isinf(upper_bound)
        current_rel_gap = (upper_bound - current_relaxation_objective)/upper_bound
        info(LOGGER, "Initial relaxation gap = $current_rel_gap")
    end


    model_bt = build_generic_model(data, model_constructor, PowerModels.post_opf)
    (upper_bound_constraint) && (constraint_obj_bound(model_bt, upper_bound))

    stats = Dict{String,Any}()
    stats["model_constructor"] = model_constructor
    stats["initial_relaxation_objective"] = current_relaxation_objective
    stats["initial_rel_gap_from_ub"] = current_rel_gap
    stats["upper_bound"] = upper_bound

    vm = var(model_bt, :vm)
    td = var(model_bt, :td)
    buses = ids(model_bt, :bus)
    buspairs = ids(model_bt, :buspairs)

    vm_lb = Dict{Any,Float64}( [bus => getlowerbound(vm[bus]) for bus in buses] )
    vm_ub = Dict{Any,Float64}( [bus => getupperbound(vm[bus]) for bus in buses] )
    td_lb = Dict{Any,Float64}( [bp => getlowerbound(td[bp]) for bp in buspairs] )
    td_ub = Dict{Any,Float64}( [bp => getupperbound(td[bp]) for bp in buspairs] )

    vm_range_init = sum([vm_ub[bus] - vm_lb[bus] for bus in buses])
    stats["vm_range_init"] = vm_range_init
    stats["avg_vm_range_init"] = vm_range_init/length(buses)

    td_range_init = sum([td_ub[bp] - td_lb[bp] for bp in buspairs])
    stats["td_range_init"] = td_range_init
    stats["avg_td_range_init"] = td_range_init/length(buspairs)

    vm_range_final = 0.0
    td_range_final = 0.0

    total_vm_reduction = Inf
    total_td_reduction = Inf
    max_vm_reduction = Inf
    max_td_reduction = Inf
    avg_vm_reduction = Inf
    avg_td_reduction = Inf

    final_relaxation_objective = NaN

    current_iteration = 0
    time_elapsed = 0.0
    parallel_time_elapsed = 0.0

    check_termination = true
    (termination == :avg) && (check_termination = (avg_vm_reduction > improvement_tol || avg_td_reduction > improvement_tol))
    (termination == :max) && (check_termination = (max_vm_reduction > improvement_tol || max_td_reduction > improvement_tol))

    while check_termination
        iter_start_time = time()
        total_vm_reduction = 0.0
        avg_vm_reduction = 0.0
        max_vm_reduction = 0.0
        total_td_reduction = 0.0
        avg_td_reduction = 0.0
        max_td_reduction = 0.0
        max_vm_iteration_time = 0.0
        max_td_iteration_time = 0.0


        # bound-tightening for the vm variables
        for bus in buses
            (vm_ub[bus] - vm_lb[bus] < min_bound_width) && (continue)

            start_time = time()
            # vm lower bound solve
            lb = NaN
            @objective(model_bt.model, Min, vm[bus])
            result_bt = solve_generic_model(model_bt, solver)
            if (result_bt["status"] == :LocalOptimal || result_bt["status"] == :Optimal)
                nlb = floor(10.0^precision * getobjectivevalue(model_bt.model))/(10.0^precision)
                (nlb > vm_lb[bus]) && (lb = nlb)
            else
                warn(LOGGER, "BT minimization problem for vm[$bus] errored - change tolerances.")
                continue
            end

            #vm upper bound solve
            ub = NaN
            @objective(model_bt.model, Max, vm[bus])
            result_bt = solve_generic_model(model_bt, solver)
            if (result_bt["status"] == :LocalOptimal || result_bt["status"] == :Optimal)
                nub = ceil(10.0^precision * getobjectivevalue(model_bt.model))/(10.0^precision)
                (nub < vm_ub[bus]) && (ub = nub)
            else
                warn(LOGGER, "BT maximization problem for vm[$bus] errored - change tolerances.")
                continue
            end
            end_time = time() - start_time
            max_vm_iteration_time = max(end_time, max_vm_iteration_time)

            # sanity checks
            (lb > ub) && (warn(LOGGER, "bt lb > ub - adjust tolerances in solver to avoid issue"); continue)
            (!isnan(lb) && lb > vm_ub[bus]) && (lb = vm_lb[bus])
            (!isnan(ub) && ub < vm_lb[bus]) && (ub = vm_ub[bus])
            isnan(lb) && (lb = vm_lb[bus])
            isnan(ub) && (ub = vm_ub[bus])

            # vm bound-reduction computation
            vm_reduction = 0.0
            if (ub - lb >= min_bound_width)
                vm_reduction = (vm_ub[bus] - vm_lb[bus]) - (ub - lb)
                vm_lb[bus] = lb
                vm_ub[bus] = ub
            else
                mean = (ub + lb)/2.0
                lb = mean - (min_bound_width/2.0)
                ub = mean + (min_bound_width/2.0)
                vm_reduction = (vm_ub[bus] - vm_lb[bus]) - (ub - lb)
                vm_lb[bus] = lb
                vm_ub[bus] = ub
            end

            total_vm_reduction += (vm_reduction)
            max_vm_reduction = max(vm_reduction, max_vm_reduction)
        end
        avg_vm_reduction = total_vm_reduction/length(buses)

        vm_range_final = sum([vm_ub[bus] - vm_lb[bus] for bus in buses])

        # bound-tightening for the td variables
        for bp in buspairs
            (td_ub[bp] - td_lb[bp] < min_bound_width) && (continue)

            start_time = time()
            # td lower bound solve
            lb = NaN
            @objective(model_bt.model, Min, td[bp])
            result_bt = solve_generic_model(model_bt, solver)
            if (result_bt["status"] == :LocalOptimal || result_bt["status"] == :Optimal)
                nlb = floor(10.0^precision * getobjectivevalue(model_bt.model))/(10.0^precision)
                (nlb > td_lb[bp]) && (lb = nlb)
            else
                warn(LOGGER, "BT minimization problem for td[$bp] errored - change tolerances")
                continue
            end

            # td upper bound solve
            ub = NaN
            @objective(model_bt.model, Max, td[bp])
            result_bt = solve_generic_model(model_bt, solver)
            if (result_bt["status"] == :LocalOptimal || result_bt["status"] == :Optimal)
                nub = ceil(10.0^precision * getobjectivevalue(model_bt.model))/(10.0^precision)
                (nub < td_ub[bp]) && (ub = nub)
            else
                warn(LOGGER, "BT maximization problem for td[$bp] errored - change tolerances.")
                continue
            end
            end_time = time() - start_time
            max_td_iteration_time = max(end_time, max_td_iteration_time)

            # sanity checks
            (lb > ub) && (warn(LOGGER, "bt lb > ub - adjust tolerances in solver to avoid issue"); continue)
            (!isnan(lb) && lb > td_ub[bp]) && (lb = td_lb[bp])
            (!isnan(ub) && ub < td_lb[bp]) && (ub = td_ub[bp])
            isnan(lb) && (lb = td_lb[bp])
            isnan(ub) && (ub = td_ub[bp])

            # td bound-reduction computation
            td_reduction = 0.0
            if (ub - lb >= min_bound_width)
                td_reduction = (td_ub[bp] - td_lb[bp]) - (ub - lb)
                td_lb[bp] = lb
                td_ub[bp] = ub
            else
                mean = (lb + ub)/2.0
                lb = mean - (min_bound_width/2.0)
                ub = mean + (min_bound_width/2.0)
                td_reduction = (td_ub[bp] - td_lb[bp]) - (ub - lb)
                td_lb[bp] = lb
                td_ub[bp] = ub
            end

            total_td_reduction += (td_reduction)
            max_td_reduction = max(td_reduction, max_td_reduction)

        end
        avg_td_reduction = total_td_reduction/length(buspairs)

        td_range_final = sum([td_ub[bp] - td_lb[bp] for bp in buspairs])

        parallel_time_elapsed += max(max_vm_iteration_time, max_td_iteration_time)

        time_elapsed += (time() - iter_start_time)

        # populate the modifications, update the data, and rebuild the bound-tightening model
        modifications = create_modifications(model_bt, vm_lb, vm_ub, td_lb, td_ub)
        PowerModels.update_data(data, modifications)
        model_bt = build_generic_model(data, model_constructor, PowerModels.post_opf)
        (upper_bound_constraint) && (constraint_obj_bound(model_bt, upper_bound))
        vm = var(model_bt, :vm)
        td = var(model_bt, :td)

        # run the qc relaxation for the updated bounds
        result_relaxation = run_opf(data, model_constructor, solver)

        if result_relaxation["status"] in status_pass
            current_rel_gap = (upper_bound - result_relaxation["objective"])/upper_bound
            final_relaxation_objective = result_relaxation["objective"]
        else
            warn(LOGGER, "relaxation solve failed in iteration $(current_iteration+1)")
            warn(LOGGER, "using the previous iteration's gap to check relative gap stopping criteria")
        end

        info(LOGGER, "iteration $(current_iteration+1), vm range: $vm_range_final, td range: $td_range_final, relaxation obj: $final_relaxation_objective")

        # termination criteria update
        (termination == :avg) && (check_termination = (avg_vm_reduction > improvement_tol || avg_td_reduction > improvement_tol))
        (termination == :max) && (check_termination = (max_vm_reduction > improvement_tol || max_td_reduction > improvement_tol))
        # interation counter update
        current_iteration += 1
        # check all the stopping criteria
        (current_iteration >= max_iter) && (info(LOGGER, "maximum iteration limit reached"); break)
        (time_elapsed > time_limit) && (info(LOGGER, "maximum time limit reached"); break)
        if (!isinf(rel_gap_tol)) && (current_rel_gap < rel_gap_tol)
            info(LOGGER, "relative optimality gap < $rel_gap_tol")
            break
        end

    end

    branches_vad_same_sign_count = 0
    for (key, branch) in data["branch"]
        is_same_sign = (branch["angmax"] >=0 && branch["angmin"] >= 0) || (branch["angmax"] <=0 && branch["angmin"] <= 0)
        (is_same_sign) && (branches_vad_same_sign_count += 1)
    end

    stats["final_relaxation_objective"] = final_relaxation_objective
    stats["final_rel_gap_from_ub"] = isnan(upper_bound) ? Inf : current_rel_gap
    stats["vm_range_final"] = vm_range_final
    stats["avg_vm_range_final"] = vm_range_final/length(buses)

    stats["td_range_final"] = td_range_final
    stats["avg_td_range_final"] = td_range_final/length(buspairs)

    stats["run_time"] = time_elapsed
    stats["iteration_count"] = current_iteration
    stats["sim_parallel_run_time"] = parallel_time_elapsed

    stats["vad_sign_determined"] = branches_vad_same_sign_count

    return data, stats

end
