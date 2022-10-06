#=
Portion of the source code below, the _lanczos4_opencv method in particular,
are copyrights of the below and are licensed under the terms below with the following
disclaimers. The source code has been significantly modified and ported to Julia.

By downloading, copying, installing or using the software you agree to this license.
If you do not agree to this license, do not download, install,
copy or use the software.


                           License Agreement
                For Open Source Computer Vision Library

Copyright (C) 2000-2008, 2017, Intel Corporation, all rights reserved.
Copyright (C) 2009, Willow Garage Inc., all rights reserved.
Copyright (C) 2014-2015, Itseez Inc., all rights reserved.
Copyright (C) 2020-2021 Miles Lucas, Tim Holy, and Mark Kittisopikul, all rights reserved
Third party copyrights are property of their respective owners.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

  * Redistribution's of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

  * Redistribution's in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * The name of the copyright holders may not be used to endorse or promote products
    derived from this software without specific prior written permission.

This software is provided by the copyright holders and contributors "as is" and
any express or implied warranties, including, but not limited to, the implied
warranties of merchantability and fitness for a particular purpose are disclaimed.
In no event shall the Intel Corporation or contributors be liable for any direct,
indirect, incidental, special, exemplary, or consequential damages
including, but not limited to, procurement of substitute goods or services;
loss of use, data, or profits; or business interruption) however caused
and on any theory of liability, whether in contract, strict liability,
or tort (including negligence or otherwise) arising in any way out of
the use of this software, even if advised of the possibility of such damage.
=#
using StaticArrays

export Lanczos4OpenCV

"""
    Lanczos4OpenCV()

Alternative implementation of Lanczos resampling using algorithm `lanczos4` function of OpenCV:
https://github.com/opencv/opencv/blob/de15636724967faf62c2d1bce26f4335e4b359e5/modules/imgproc/src/resize.cpp#L917-L946
"""
struct Lanczos4OpenCV <: AbstractLanczos end

degree(::Lanczos4OpenCV) = 4

value_weights(::Lanczos4OpenCV, δx) = _lanczos4_opencv(δx)

# s45 = sqrt(2)/2
const s45 = 0.70710678118654752440084436210485

# l4_2d_cs is a lookup table that could be generated by
# x = (0:7)*45*5
# l4_2d_cs = [cosd.(x) sind.(x)]'
const l4_2d_cs = SA[1 0; -s45 -s45; 0 1; s45 -s45; -1 0; s45 s45; 0 -1; -s45 s45]


function _lanczos4_opencv(δx)
    p_4 = π / 4
    y0 = -(δx + 3) * p_4
    s0, c0 = sincos(y0)
    cs = ntuple(8) do i
        y = (δx + 4 - i) * p_4
        # Improve precision of Lanczos OpenCV4 #451, avoid NaN
        if iszero(y)
            y = eps(oneunit(y))/8
        end
        # Numerator is the sin subtraction identity
        # It is equivalent to the following
        # f(δx,i) = sin( π/4*( 5*(i-1)-δx-3 ) )
        (l4_2d_cs[i, 1] * s0 + l4_2d_cs[i, 2] * c0) / y^2
    end
    sum_cs = sum(cs)
    normed_cs = ntuple(i -> cs[i] / sum_cs, Val(8))
    return normed_cs
end