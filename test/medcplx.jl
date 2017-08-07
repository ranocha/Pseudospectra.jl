module M
# 225x225 complex dense
# Compare to S&P, Fig. 60.2

using Pseudospectra

include("testplotter.jl")

opts = Dict{Symbol,Any}(:ax => [-1.1,1.2,-1.1,1.1], :npts => 60,
                        :levels => -5:0.5:-1)
A = Pseudospectra.landau_fox_li(225,16)

ps_data = new_matrix(A,opts)
driver!(ps_data,opts,gs)

end