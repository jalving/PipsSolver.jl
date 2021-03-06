# Julia Interface to Pips-NLP
# Feng Qiang, Cosmin G. Petra
# Argonne National Laboratory, 2016

# Wrapper for the parallel/structured PIPS-NLP interface
module PipsNlpSolver
import MPI
using Libdl

try
  sharedLib=ENV["PIPS_NLP_PAR_SHARED_LIB"]

  # Explicitly check if the file exists. dlopen sometimes does not throw an
  # error for invalid filenames, resulting in a seg fault)
  if(!isfile(sharedLib))
    error(string("The specified shared library ([", sharedLib, "]) does not exist"))
  end
  global const libparpipsnlp=Libdl.dlopen(get(ENV,"PIPS_NLP_PAR_SHARED_LIB",""))
catch
  @warn("Could not load PIPS-NLP shared library. Make sure the ENV variable 'PIPS_NLP_PAR_SHARED_LIB' points to its location, usually in the PIPS repo at PIPS/build_pips/PIPS-NLP/libparpipsnlp.so")
  rethrow()
end
abstract type ModelInterface end
#######################
mutable struct PipsModel <: ModelInterface
    sense::Symbol
    status::Int
    nscen::Int
    rowmap::Dict{Int,Int}
    colmap::Dict{Int,Int}
    eq_rowmap::Dict{Int,Int}
    inq_rowmap::Dict{Int,Int}

    get_num_scen::Function
    get_sense::Function

    get_status::Function
    get_num_rows::Function
    get_num_cols::Function
    get_num_eq_cons::Function
    get_num_ineq_cons::Function

    set_status::Function
    set_num_rows::Function
    set_num_cols::Function
    set_num_eq_cons::Function
    set_num_ineq_cons::Function

    str_init_x0::Function
    str_prob_info::Function
    str_eval_f::Function
    str_eval_g::Function
    str_eval_grad_f::Function
    str_eval_jac_g::Function
    str_eval_h::Function
    str_write_solution::Function


    function PipsModel(sense::Symbol,status::Int,nscen::Int, str_init_x0, str_prob_info, str_eval_f, str_eval_g,str_eval_grad_f,str_eval_jac_g, str_eval_h, str_write_solution)
        instance = new(sense,status,nscen,Dict{Int,Int}(),Dict{Int,Int}(),Dict{Int,Int}(),Dict{Int,Int}())
        instance.str_init_x0 = str_init_x0
        instance.str_prob_info = str_prob_info
        instance.str_eval_f = str_eval_f
        instance.str_eval_g = str_eval_g
        instance.str_eval_grad_f = str_eval_grad_f
        instance.str_eval_jac_g = str_eval_jac_g
        instance.str_eval_h = str_eval_h
	    instance.str_write_solution = str_write_solution

        instance.get_num_scen = function()
            return instance.nscen
        end
        instance.get_sense = function()
            return instance.sense
        end
        instance.get_status = function()
            return instance.status
        end
        instance.get_num_rows = function(id::Integer)
            return instance.rowmap[id]
        end
        instance.get_num_cols = function(id::Integer)
            return instance.colmap[id]
        end
        instance.get_num_eq_cons = function(id::Integer)
            return instance.eq_rowmap[id]
        end
        instance.get_num_ineq_cons = function(id::Integer)
            return instance.inq_rowmap[id]
        end
        instance.set_status = function(s::Integer)
            instance.status = s
        end
        instance.set_num_rows = function(id::Integer, v::Integer)
            return instance.rowmap[id] = v
        end
        instance.set_num_cols = function(id::Integer, v::Integer)
            return instance.colmap[id] = v
        end
        instance.set_num_eq_cons = function(id::Integer, v::Integer)
            return instance.eq_rowmap[id] = v
        end
        instance.set_num_ineq_cons = function(id::Integer, v::Integer)
            return instance.inq_rowmap[id] = v
        end
        return instance
    end
end

#######################
mutable struct PipsNlpProblemStruct
    ref::Ptr{Nothing}
    model::ModelInterface
    comm::MPI.Comm
    prof::Bool

    n_iter::Int
    t_jl_init_x0::Float64
    t_jl_str_prob_info::Float64
    t_jl_eval_f::Float64
    t_jl_eval_g::Float64
    t_jl_eval_grad_f::Float64

    t_jl_eval_jac_g::Float64
    t_jl_str_eval_jac_g::Float64
    t_jl_eval_h::Float64
    t_jl_str_eval_h::Float64
    t_jl_write_solution::Float64

    t_jl_str_total::Float64
    t_jl_eval_total::Float64

    function PipsNlpProblemStruct(comm, model, prof)
        prob = new(C_NULL, model, comm, prof,-3
            ,0.0,0.0,0.0,0.0,0.0
            ,0.0,0.0,0.0,0.0,0.0
            ,0.0,0.0
            )
        #finalizer(prob, freeProblemStruct)
        finalizer(freeProblemStruct, prob)
        return prob
    end
end

struct CallBackData
	prob::Ptr{Nothing}
	row_node_id::Cint
    col_node_id::Cint
    flag::Cint  #this wrapper ignore this flag as it is only for problems without linking constraint
end

export  ModelInterface, PipsModel,
        createProblemStruct, solveProblemStruct

###########################################################################
# Callback wrappers
###########################################################################

function str_init_x0_wrapper(x0_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})
    data = unsafe_load(cbd)
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    @assert(rowid == colid)
    n0 = prob.model.get_num_cols(colid)
    x0 = unsafe_wrap(Array,x0_ptr,n0)

    # if prob.prof
    #     t1 = time()
    # end
    t = @elapsed prob.model.str_init_x0(colid,x0)
    if prob.prof
        prob.t_jl_init_x0 += t
    end
    return Int32(1)
end

# prob info (prob_info)
function str_prob_info_wrapper(n_ptr::Ptr{Cint}, col_lb_ptr::Ptr{Float64}, col_ub_ptr::Ptr{Float64}, m_ptr::Ptr{Cint}, row_lb_ptr::Ptr{Float64}, row_ub_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})

    data = unsafe_load(cbd)
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    flag = data.flag
    @assert(rowid == colid)

	mode = (col_lb_ptr == C_NULL&&col_ub_ptr==C_NULL&&row_lb_ptr==C_NULL&&row_ub_ptr==C_NULL) ? (:Structure) : (:Values)
    #@show flag
    if flag != 1
        #@show mode
    	if(mode==:Structure)
            col_lb = unsafe_wrap(Array,col_lb_ptr,0)
            col_ub = unsafe_wrap(Array,col_ub_ptr,0)
            row_lb = unsafe_wrap(Array,row_lb_ptr,0)
            row_ub = unsafe_wrap(Array,row_ub_ptr,0)
            # if prob.prof
            #     tic()
            # end
    		t = @elapsed (n,m) = prob.model.str_prob_info(colid,flag,mode,col_lb,col_ub,row_lb,row_ub)
            if prob.prof
                prob.t_jl_str_prob_info += t
            end

    		unsafe_store!(n_ptr,convert(Cint,n)::Cint)
    		unsafe_store!(m_ptr,convert(Cint,m)::Cint)
            # @show typeof(colid), typeof(m)
    		prob.model.set_num_rows(colid, m)
    		prob.model.set_num_cols(colid, n)
    	else
    		n = unsafe_load(n_ptr)
    		m = unsafe_load(m_ptr)
    		col_lb = unsafe_wrap(Array,col_lb_ptr,n)
    		col_ub = unsafe_wrap(Array,col_ub_ptr,n)
    		row_lb = unsafe_wrap(Array,row_lb_ptr,m)
    		row_ub = unsafe_wrap(Array,row_ub_ptr,m)

            # if prob.prof
            #     tic()
            # end
    		t = @elapsed prob.model.str_prob_info(colid,flag,mode,col_lb,col_ub,row_lb,row_ub)
            if prob.prof
                prob.t_jl_str_prob_info += t
            end

    		neq = 0
    		nineq = 0
    		for i = 1:length(row_lb)
    			if row_lb[i] == row_ub[i]
    				neq += 1
    			else
    				nineq += 1
    			end
    		end
    		@assert(neq+nineq == length(row_lb) == m)
    		prob.model.set_num_eq_cons(colid,neq)
    		prob.model.set_num_ineq_cons(colid,nineq)
    	end
    else
	#println("prob_info: ",mode,flag)
        @assert flag == 1
        if mode == :Structure
            col_lb = unsafe_wrap(Array,col_lb_ptr,0)
            col_ub = unsafe_wrap(Array,col_ub_ptr,0)
            row_lb = unsafe_wrap(Array,row_lb_ptr,0)
            row_ub = unsafe_wrap(Array,row_ub_ptr,0)
            (n,m) = prob.model.str_prob_info(colid,flag,mode,col_lb,col_ub,row_lb,row_ub)
            # @show n,m
            unsafe_store!(m_ptr,convert(Cint,m)::Cint)
        else
	# edited by yankai
            m = unsafe_load(m_ptr)
	        col_lb = unsafe_wrap(Array,col_lb_ptr,0)
            col_ub = unsafe_wrap(Array,col_ub_ptr,0)
            row_lb = unsafe_wrap(Array,row_lb_ptr,m)
            row_ub = unsafe_wrap(Array,row_ub_ptr,m)
            prob.model.str_prob_info(colid,flag,mode,col_lb,col_ub,row_lb,row_ub)
        end
    end
    # @show "exit  julia - str_prob_info_wrapper "
	return Int32(1)
end
# Objective (eval_f)
function str_eval_f_wrapper(x0_ptr::Ptr{Float64}, x1_ptr::Ptr{Float64}, obj_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})
    # @show " julia - eval_f_wrapper "
    data = unsafe_load(cbd)
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    @assert(rowid == colid)
    n0 = prob.model.get_num_cols(0)
    n1 = prob.model.get_num_cols(colid)
    # Calculate the new objective
    x0 = unsafe_wrap(Array,x0_ptr, n0)
    x1 = unsafe_wrap(Array,x1_ptr, n1)

    # if prob.prof
    #     tic()
    # end
    t = @elapsed new_obj = convert(Float64, prob.model.str_eval_f(colid,x0,x1))::Float64
    if prob.prof
        prob.t_jl_eval_f += t
    end
    # Fill out the pointer
    unsafe_store!(obj_ptr, new_obj)
    # Done
    # @show "exit julia - eval_f_wrapper "
    return Int32(1)
end

# Constraints (eval_g)
function str_eval_g_wrapper(x0_ptr::Ptr{Float64}, x1_ptr::Ptr{Float64}, eq_g_ptr::Ptr{Float64}, inq_g_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})
    # @show " julia - eval_g_wrapper "
    data = unsafe_load(cbd)
    # @show data
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    @assert(rowid == colid)
    n0 = prob.model.get_num_cols(0)
    n1 = prob.model.get_num_cols(colid)
    x0 = unsafe_wrap(Array,x0_ptr, n0)
    x1 = unsafe_wrap(Array,x1_ptr, n1)
    # Calculate the new constraint values

    #println("rowid",rowid)
    #println(prob.model)
    # if MPI.Comm_rank(MPI.COMM_WORLD) == 1
    #     println("rank: ",MPI.Comm_rank(MPI.COMM_WORLD),"rowid: ",rowid)
    # end
    neq = prob.model.get_num_eq_cons(rowid)
    nineq = prob.model.get_num_ineq_cons(rowid)
    new_eq_g = unsafe_wrap(Array,eq_g_ptr,neq)
    new_inq_g = unsafe_wrap(Array,inq_g_ptr, nineq)

    # if prob.prof
    #     tic()
    # end
    t = @elapsed prob.model.str_eval_g(colid,x0,x1,new_eq_g,new_inq_g)
    if prob.prof
        prob.t_jl_eval_g += t
    end
    # Done
    # @show " exit julia - eval_g_wrapper "
    return Int32(1)
end

# Objective gradient (eval_grad_f)
function str_eval_grad_f_wrapper(x0_ptr::Ptr{Float64}, x1_ptr::Ptr{Float64}, grad_f_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})
    # @show " julia -  eval_grad_f_wrapper "
    # Extract Julia the problem from the pointer
    # @show cbd
    data = unsafe_load(cbd)
    # @show data
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    n0 = prob.model.get_num_cols(0)
    n1 = prob.model.get_num_cols(rowid)
    # @show n0,n1
    x0 = unsafe_wrap(Array,x0_ptr, n0)
    x1 = unsafe_wrap(Array,x1_ptr, n1)
    # Calculate the gradient
    grad_len = prob.model.get_num_cols(colid)
    new_grad_f = unsafe_wrap(Array,grad_f_ptr, grad_len)

    # if prob.prof
    #     tic()
    # end
    t = @elapsed prob.model.str_eval_grad_f(rowid,colid,x0,x1,new_grad_f)
    if prob.prof
        prob.t_jl_eval_grad_f += t
    end
    if prob.model.get_sense() == :Max
        new_grad_f *= -1.0
    end
    # Done
    # @show " julia -  eval_grad_f_wrapper "
    return Int32(1)
end

# Jacobian (eval_jac_g)
function str_eval_jac_g_wrapper(x0_ptr::Ptr{Float64}, x1_ptr::Ptr{Float64},
	e_nz_ptr::Ptr{Cint}, e_values_ptr::Ptr{Float64}, e_row_ptr::Ptr{Cint}, e_col_ptr::Ptr{Cint},
	i_nz_ptr::Ptr{Cint}, i_values_ptr::Ptr{Float64}, i_row_ptr::Ptr{Cint}, i_col_ptr::Ptr{Cint},
	cbd::Ptr{CallBackData}
	)
    # @show " julia -  eval_jac_g_wrapper "
    # Extract Julia the problem from the pointer
    data = unsafe_load(cbd)
    # @show data
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    flag = data.flag
    n0 = prob.model.get_num_cols(0)
    n1 = prob.model.get_num_cols(rowid) #we can do this because of 2-level and no linking constraint
    # @show n0, n1
    x0 = unsafe_wrap(Array,x0_ptr, n0)
    x1 = unsafe_wrap(Array,x1_ptr, n1)
    # @show x0
    # @show x1
    nrow = prob.model.get_num_rows(rowid)
    ncol = prob.model.get_num_cols(colid)
    #@show prob
    # Determine mode
    mode = (e_row_ptr == C_NULL &&e_col_ptr == C_NULL&&e_values_ptr == C_NULL && i_values_ptr == C_NULL&&i_row_ptr == C_NULL &&i_col_ptr == C_NULL) ? (:Structure) : (:Values)
    #@show mode
    if flag != 1
        if(mode == :Structure)
        	e_values = unsafe_wrap(Array,e_values_ptr,0)
    		e_colptr = unsafe_wrap(Array,e_col_ptr,0)
    		e_rowidx = unsafe_wrap(Array,e_row_ptr,0)
    		i_values = unsafe_wrap(Array,i_values_ptr,0)
    		i_colptr = unsafe_wrap(Array,i_col_ptr,0)
    		i_rowidx = unsafe_wrap(Array,i_row_ptr,0)
            # if prob.prof
            #     tic()
            # end
            t = @elapsed (e_nz,i_nz) = prob.model.str_eval_jac_g(rowid,colid,flag,x0,x1,mode,e_rowidx,e_colptr,e_values,i_rowidx,i_colptr,i_values)
            if prob.prof
                prob.t_jl_str_eval_jac_g += t
            end
    		unsafe_store!(e_nz_ptr,convert(Cint,e_nz)::Cint)
    		unsafe_store!(i_nz_ptr,convert(Cint,i_nz)::Cint)
    		# @show "structure - ",(e_nz,i_nz)
        else
        	e_nz = unsafe_load(e_nz_ptr)
        	e_values = unsafe_wrap(Array,e_values_ptr,e_nz)
        	e_rowidx = unsafe_wrap(Array,e_row_ptr, e_nz)
        	e_colptr = unsafe_wrap(Array,e_col_ptr, ncol+1)
        	i_nz = unsafe_load(i_nz_ptr)
        	# @show "values - ",(e_nz,i_nz), ncol
        	i_values = unsafe_wrap(Array,i_values_ptr,i_nz)
        	i_rowidx = unsafe_wrap(Array,i_row_ptr, i_nz)
        	i_colptr = unsafe_wrap(Array,i_col_ptr, ncol+1)

            # if prob.prof
            #     tic()
            # end
        	t = @elapsed prob.model.str_eval_jac_g(rowid,colid,flag,x0,x1,mode,e_rowidx,e_colptr,e_values,i_rowidx,i_colptr,i_values)
            if prob.prof
                prob.t_jl_eval_jac_g += t
            end
        end
    else
        @assert flag == 1
        if mode == :Structure
                e_values = unsafe_wrap(Array,e_values_ptr,0)
                e_colptr = unsafe_wrap(Array,e_col_ptr,0)
                e_rowidx = unsafe_wrap(Array,e_row_ptr,0)
                i_values = unsafe_wrap(Array,i_values_ptr,0)
                i_colptr = unsafe_wrap(Array,i_col_ptr,0)
                i_rowidx = unsafe_wrap(Array,i_row_ptr,0)
            # if prob.prof
            #     tic()
            # end
            t = @elapsed (e_nz,i_nz) = prob.model.str_eval_jac_g(rowid,colid,flag, x0,x1,mode,e_rowidx,e_colptr,e_values,i_rowidx,i_colptr,i_values)
            if prob.prof
                prob.t_jl_str_eval_jac_g += t
            end
            unsafe_store!(e_nz_ptr,convert(Cint,e_nz)::Cint)
            unsafe_store!(i_nz_ptr,convert(Cint,i_nz)::Cint)
        else
            e_nz = unsafe_load(e_nz_ptr)
            e_values = unsafe_wrap(Array,e_values_ptr,e_nz)
            e_rowidx = unsafe_wrap(Array,e_row_ptr, e_nz)
            e_colptr = unsafe_wrap(Array,e_col_ptr, ncol+1)
            i_nz = unsafe_load(i_nz_ptr)
            i_values = unsafe_wrap(Array,i_values_ptr,i_nz)
            i_rowidx = unsafe_wrap(Array,i_row_ptr, i_nz)
            i_colptr = unsafe_wrap(Array,i_col_ptr, ncol+1)
            # if prob.prof
            #     tic()
            # end
            t = @elapsed prob.model.str_eval_jac_g(rowid,colid,flag, x0,x1,mode,e_rowidx,e_colptr,e_values,i_rowidx,i_colptr,i_values)
            if prob.prof
                prob.t_jl_eval_jac_g += t
            end
        end
    end
    # Done
    #@show "exit julia -  eval_jac_g_wrapper "
    return Int32(1)
end

# Hessian
function str_eval_h_wrapper(x0_ptr::Ptr{Float64}, x1_ptr::Ptr{Float64}, lambda_ptr::Ptr{Float64}, nz_ptr::Ptr{Cint}, values_ptr::Ptr{Float64}, row_ptr::Ptr{Cint}, col_ptr::Ptr{Cint}, cbd::Ptr{CallBackData})
    # @show " julia - eval_h_wrapper "
    # Extract Julia the problem from the pointer
    data = unsafe_load(cbd)
    # @show data
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    # @show prob.prof
    rowid = data.row_node_id
    colid = data.col_node_id

    high = max(rowid,colid)
    low  = min(rowid,colid)
    n0 = prob.model.get_num_cols(0)
    n1 = prob.model.get_num_cols(high)
    x0 = unsafe_wrap(Array,x0_ptr, n0)
    x1 = unsafe_wrap(Array,x1_ptr, n1)

    ncol = prob.model.get_num_cols(low)
    g0 = prob.model.get_num_rows(high)

    lambda = unsafe_wrap(Array,lambda_ptr, g0)
    obj_factor = 1.0
    if prob.model.get_sense() == :Max
        obj_factor *= -1.0
    end
    # Did the user specify a Hessian
    mode = (values_ptr == C_NULL) ? (:Structure) : (:Values)
    if(mode == :Structure)
    	values = unsafe_wrap(Array,values_ptr,0)
		colptr = unsafe_wrap(Array,col_ptr,0)
		rowidx = unsafe_wrap(Array,row_ptr,0)
        # if prob.prof
        #     tic()
        # end
		t = @elapsed nz = prob.model.str_eval_h(rowid,colid,x0,x1,obj_factor,lambda,mode,rowidx,colptr,values)
        if prob.prof
            prob.t_jl_str_eval_h += t
        end
		unsafe_store!(nz_ptr,convert(Cint,nz)::Cint)
		# @show "structure - ", nz
    else
    	nz = unsafe_load(nz_ptr)
    	values = unsafe_wrap(Array,values_ptr, nz)
    	rowidx = unsafe_wrap(Array,row_ptr, nz)
    	colptr = unsafe_wrap(Array,col_ptr, ncol+1)
    	# @show "value - ", nz
        # if prob.prof
        #     tic()
        # end
    	t = @elapsed prob.model.str_eval_h(rowid,colid,x0,x1,obj_factor,lambda,mode,rowidx,colptr,values)
        if prob.prof
            prob.t_jl_eval_h += t
        end
    end
    # Done
    if prob.prof
        if rowid == colid == 0
            prob.n_iter += 1
            if prob.n_iter == 0
                prob.t_jl_str_total = t_reset(prob)
            end
        end
    end
    # @show "exit  julia - eval_h_wrapper "
    return Int32(1)
end

#write solution
function str_write_solution_wrapper(x_ptr::Ptr{Float64}, y_eq_ptr::Ptr{Float64}, y_ieq_ptr::Ptr{Float64}, cbd::Ptr{CallBackData})
    data = unsafe_load(cbd)
    # @show data
    userdata = data.prob
    prob = unsafe_pointer_to_objref(userdata)::PipsNlpProblemStruct
    rowid = data.row_node_id
    colid = data.col_node_id
    @assert rowid == colid

    nx = prob.model.get_num_cols(rowid)
    neq = prob.model.get_num_eq_cons(rowid)
    nieq = prob.model.get_num_ineq_cons(rowid)
    x = unsafe_wrap(Array,x_ptr, nx)
    y_eq = unsafe_wrap(Array,y_eq_ptr,neq)
    y_ieq = unsafe_wrap(Array,y_ieq_ptr,nieq)
    # if prob.prof
    #     tic()
    # end
    t = @elapsed prob.model.str_write_solution(rowid,x,y_eq,y_ieq)
    if prob.prof
        prob.t_jl_write_solution += t
    end

    return Int32(1)
end
###########################################################################
# C function wrappers
###########################################################################

function createProblemStruct(comm::MPI.Comm, model::ModelInterface, prof::Bool)
	# println(" createProblemStruct  -- julia")
	str_init_x0_cb = @cfunction(str_init_x0_wrapper, Cint, (Ptr{Float64}, Ptr{CallBackData}))
    str_prob_info_cb = @cfunction(str_prob_info_wrapper, Cint, (Ptr{Cint}, Ptr{Float64}, Ptr{Float64}, Ptr{Cint}, Ptr{Float64}, Ptr{Float64}, Ptr{CallBackData}) )
    str_eval_f_cb = @cfunction(str_eval_f_wrapper,Cint, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{CallBackData}) )
    str_eval_g_cb = @cfunction(str_eval_g_wrapper,Cint, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{CallBackData}) )
    str_eval_grad_f_cb = @cfunction(str_eval_grad_f_wrapper, Cint, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{CallBackData}) )
    str_eval_jac_g_cb = @cfunction(str_eval_jac_g_wrapper, Cint, (Ptr{Float64}, Ptr{Float64},
    	Ptr{Cint}, Ptr{Float64}, Ptr{Cint}, Ptr{Cint},
    	Ptr{Cint}, Ptr{Float64}, Ptr{Cint}, Ptr{Cint},
    	Ptr{CallBackData}))
    str_eval_h_cb = @cfunction(str_eval_h_wrapper, Cint, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Cint}, Ptr{Float64}, Ptr{Cint}, Ptr{Cint}, Ptr{CallBackData}))
    str_write_solution_cb = @cfunction(str_write_solution_wrapper, Cint, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{CallBackData}))

    # println(" callback created ")
    prob = PipsNlpProblemStruct(comm, model, prof)
    # @show prob
    libparpipsnlp=Libdl.dlopen(get(ENV,"PIPS_NLP_PAR_SHARED_LIB",""))
    ret = ccall(Libdl.dlsym(libparpipsnlp,:CreatePipsNlpProblemStruct),Ptr{Nothing},
            (MPI.Comm,
            Cint, Ptr{Nothing}, Ptr{Nothing},Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing},Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing},Any
            # ,Ptr{Void}, Ptr{Void}  #comply with link interface from yankai
            ),
            comm,
            model.get_num_scen(),
            str_init_x0_cb,
            str_prob_info_cb,
            str_eval_f_cb,
            str_eval_g_cb,
            str_eval_grad_f_cb,
            str_eval_jac_g_cb,
            str_eval_h_cb,
            str_write_solution_cb,
            prob
            # ,Ptr{Void}(0), Ptr{Void}(0)
            )
    if ret == C_NULL
        error("PIPS-NLP: Failed to construct problem.")
    else
        prob.ref = ret
    end
    return prob
end

function solveProblemStruct(prob::PipsNlpProblemStruct)
    # println("solveProblemStruct - julia")
    # @show prob

    libparpipsnlp=Libdl.dlopen(get(ENV,"PIPS_NLP_PAR_SHARED_LIB",""))
    ret = ccall(Libdl.dlsym(libparpipsnlp,:PipsNlpSolveStruct), Cint,
            (Ptr{Nothing},),
            prob.ref)
    # @show ret
    prob.model.set_status(Int(ret))

    prob.t_jl_eval_total = report_total_now(prob)
    # @show prob
    return prob.model.get_status()
end

function freeProblemStruct(prob::PipsNlpProblemStruct)
    # @show "freeProblemStruct"
    libparpipsnlp=Libdl.dlopen(get(ENV,"PIPS_NLP_PAR_SHARED_LIB",""))
    ret = ccall(Libdl.dlsym(libparpipsnlp,:FreePipsNlpProblemStruct),
            Nothing, (Ptr{Nothing},),
            prob.ref)
    # @show ret
    return ret
end

function report_total_now(prob::PipsNlpProblemStruct)
    total = 0.0
    total += prob.t_jl_init_x0
    total += prob.t_jl_str_prob_info
    total += prob.t_jl_eval_f
    total += prob.t_jl_eval_g
    total += prob.t_jl_eval_grad_f
    total += prob.t_jl_eval_jac_g
    total += prob.t_jl_str_eval_jac_g
    total += prob.t_jl_eval_h
    total += prob.t_jl_str_eval_h
    total += prob.t_jl_write_solution
    return total
end

function t_reset(prob::PipsNlpProblemStruct)
    total = report_total_now(prob)
    prob.t_jl_init_x0  = 0.0
    prob.t_jl_str_prob_info  = 0.0
    prob.t_jl_eval_f = 0.0
    prob.t_jl_eval_g = 0.0
    prob.t_jl_eval_grad_f = 0.0
    prob.t_jl_eval_jac_g = 0.0
    prob.t_jl_str_eval_jac_g = 0.0
    prob.t_jl_eval_h = 0.0
    prob.t_jl_str_eval_h = 0.0
    prob.t_jl_write_solution = 0.0
    return total
end

end
