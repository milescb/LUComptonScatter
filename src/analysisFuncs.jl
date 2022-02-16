using LinearAlgebra, DataFrames, Findpeaks, Smoothers, Interpolations, LsqFit

"""
    expected_energy(θ, Eγ)

Compute expected compton energy from scattering off electrons. 

# Arguments
- `θ`: scattering angle in degrees
- `Eγ`: photon source energy
"""
function expected_energy(θ, Eγ)
    α = Eγ / (511)
    E = Eγ * (1 / (1 + α*(1 - cos(θ * (π / 180)))))
    return E
end

"""
    read_Txt(path_to_file::String)

Create DataFrame from .Txt file generated by Maestro. 

To get .Txt file from Maestro: `file > print > print to text` 
and save as a .Txt file in a location you can easily locate. 
"""
function read_Txt(path_to_file::String)

    file = open(path_to_file, "r")

    ## collect data. Note that this is 1-indexed
    data = Vector{Int64}()

    for ln in eachline(file)
        if !isempty(ln) && ln[1] == ' '
            tempNum::String = "";
            dataPass = false
            for i in 1:length(ln)
                if dataPass && ln[i] != ' '
                    tempNum *= ln[i]
                elseif dataPass && ln[i - 1] != ' ' && ln[i] == ' ' && !isempty(tempNum)
                    append!(data, parse(Int64, tempNum)) # add number to vector
                    tempNum = "";
                end
                if dataPass && i == length(ln) # if add the end of a row, append number to vector
                    append!(data, parse(Int64, tempNum)) # add number to vector
                    tempNum = "";
                end
                if ln[i] == ':' dataPass = true end
            end
        end
    end

    close(file)

    lines = Vector{Int64}()
    line = 0
    for i in 1:length(data)
        line += 1
        append!(lines, line)
    end

    return DataFrame(Lines = lines, Counts = data)
end

"""
    get_xy_data(data::DataFrame, lowerLim::Int64, f::Function)

Scale x-axis to computed energy calibration via the linear function `f`

# Arguments
- `data::DataFrame`: data to be scaled
- `lowerLim::Int64`: cut off data below this index
- `f::Function`: computed calibration
"""
function get_xy_data(data::DataFrame, lowerLim::Int64, f::Function)
    xCh = data[!, 1]
    y = data[!, 2]

    #exclude low energy noise
    xCh = xCh[lowerLim:length(xCh)]
    y = y[lowerLim:length(y)]

    return f.(xCh), y
end

"""
    select_part(x0::Vector, y0::Vecotor, lower, upper)

Selects data between `lower` and `upper` limits of the x-axis
"""
function select_part(x0, y0, lower, upper)

    lims = Vector{Int64}()

    #find limits for filtering ydata
    for i in 1:length(y0)
        if x0[i] > lower
            push!(lims, i)
            break
        end
    end
    for i in 1:length(y0)
        if x0[length(x0) - i] < upper
            push!(lims, length(x0) - i)
            break
        end
    end

    return x0[lims[1]:lims[2]], y0[lims[1]:lims[2]]
end

"""
    weighted_mean(x::Vector, w::Vector)

Compute weighted mean of `x` with weights `w`
"""
function weighted_mean(x, w)
    meanVal = 0.0
    w = normalize(w, 1)
    for i in 1:length(x)
        meanVal += x[i] * w[i]
    end
    return meanVal;
end

"""
    remove_missing(x::Vector)

Remove `missing` values from a vector
"""
function remove_missing(x::Vector)
    xNew = Vector{Float64}()
    for i in 1:length(x)
        if ismissing(x[i])
            push!(xNew, 0.0)
        else
            push!(xNew, x[i])
        end
    end
    return xNew
end

"""
    find_peak_ends(x::Vector, y::Vector, peak::Float64, tol::Float64)

Compute endings of peak up to a give tolerance `tol`. 
The value of `tol` represents the value of the derivative at which to 
truncate the peak. 

See also [`peak_parameters`](@ref), [`get_peak_value`](@ref)
"""
function find_peak_ends(x::Vector, y::Vector, peak, tol)

    #create interpolation
    itp = interpolate((x,), y, Gridded(Linear()));
    dx(x) = only(Interpolations.gradient(itp, x))

    # vector of outputs
    turningPoints = Vector{Int64}()

    #going left from the peak
    for i in 1:(peak + 20)
        if abs(dx(x[peak - i - 20])) < tol
            push!(turningPoints, peak - i - 20)
            break
        end
    end 
    push!(turningPoints, peak) #add peak
    #going to the right from the peak
    for i in 1:(length(x) - peak - 15)
        if abs(dx(x[peak + i + 20])) < tol
            push!(turningPoints, peak + i + 20)
            break
        end
    end

    return turningPoints
end

"""
    peak_parameters(x, y0, SmoothParam, promParam, tol)

Compute location of peaks and endings of peaks as well as
a smoothing of the data. 

# Arguments 
- `x::Vector`: x-values of graph
- `y0::Vector`: y-values of graph
- `SmoothParam::Int`: size of weighted average region for data smoothing
- `promParam::Float64`: prominance of peaks to search for 
- `tol::Float64`: tolance of location of peak ending
```
See also [`find_peak_ends`](@ref), [`get_peak_value`](@ref)
"""
function peak_parameters(x::Vector, y0::Vector, SmoothParam::Int, promParam::Float64, tol::Float64)

    #smooth data
    y = remove_missing(sma(y0, SmoothParam, true))

    #find peaks
    peaks = findpeaks(y, x, min_prom=promParam)

    #get peaks and ends of peaks
    peakData = Vector{Vector{Int64}}()
    for i in 1:length(peaks)
        append!(peakData, [find_peak_ends(x, y, peaks[i], tol)])
    end

    return peakData, y
end

"""
    get_peak_value(x::Vector, y::Vector, peak::Vector)

Compute weighted mean about a peak 

# Arguments
- `x::Vector`: x-values
- `y::Vector`: y-values
- `peak::Vector`: one of the peaks obtained from the function `peak_parameters()`

See also [`peak_parameters`](@ref), [`find_peak_ends`](@ref), [`weighted_mean`](@ref)
"""
function get_peak_value(x::Vector, y::Vector, peak::Vector)

    #find value of the background
    background = (y[peak[1]] + y[peak[3]]) / 2
    filterPeak = 0.2 * (y[peak[2]] - background) + background

    #find indices of where 20% of background intersects with plot
    scaledVals = Vector{Int64}()
    #from left edge to right
    for i in 1:length(y)
        if y[peak[1] + i] > filterPeak
            push!(scaledVals, peak[1] + i)
            break
        end
    end
    #from right edge to left
    for i in 1:length(y)
        if y[peak[3] - i] > filterPeak
            push!(scaledVals, peak[3] - i)
            break
        end
    end

    #compute weighted mean over this new section
    xScaled, yScaled = x[scaledVals[1]:scaledVals[2]], y[scaledVals[1]:scaledVals[2]]
    peakVal = weighted_mean(xScaled, yScaled)

    return peakVal; 

end

"""
    gauss(x::Vector, p::Vector)

Compute standard gaussion from `x` data with fit parameters `p`

# Fit parameters
- `p[1]`: scaling constant 
- `p[2]`: σ
- `p[3]`: μ
"""
@. gauss(x, p) = p[1] * (1/(p[2] * sqrt(2*π))) * exp((-1/2)*((x - p[3])^2) / p[2]^2)

"""
    fit_to_gauss(x::Vector, y::Vector, pk::Vector)

Fit data to gaussian around a peak
"""
function fit_to_gauss(x::Vector, y::Vector, pk::Vector)

    #find value of the background
    background = (y[pk[1]] + y[pk[3]]) / 2
    filterPeak = 0.2 * (y[pk[2]] - background) + background

    #find indices of where 20% of background intersects with plot
    scaledVals = Vector{Int64}()
    #from left edge to right
    for i in 1:length(y)
        if y[pk[1] + i] > filterPeak
            push!(scaledVals, pk[1] + i)
            break
        end
    end
    #from right edge to left
    for i in 1:length(y)
        if y[pk[3] - i] > filterPeak
            push!(scaledVals, pk[3] - i)
            break
        end
    end

    # starting conditions
    p0 = [500.0, 500.0, 500.0]
    fit = curve_fit(gauss, x[scaledVals[1]:scaledVals[2]], y[scaledVals[1]:scaledVals[2]], p0) #perform fit
    Params = fit.param
    Errors = standard_errors(fit)

    return Params, Errors

end
    
