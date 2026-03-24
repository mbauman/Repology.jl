using Repology
using Test

@testset "identify_upstream" begin
    @test Repology.identify_upstream("https://www.cairographics.org/releases/cairo-1.32.0.tar.xz", "") == ("cairo-graphics-library", "1.32.0")
    @test Repology.identify_upstream("https://download.gnome.org/sources/glib-networking/2.74/glib-networking-2.74.0.tar.xz", "") == ("glib-networking", "2.74.0")
    @test Repology.identify_upstream("https://downloads.sourceforge.net/project/gnuplot/gnuplot/6.0.3/gnuplot-6.0.3.tar.gz", "") == ("gnuplot", "6.0.3")
    @test Repology.identify_upstream("https://sourceforge.net/projects/graphicsmagick/files/graphicsmagick/1.3.45/GraphicsMagick-1.3.45.tar.xz", "") == ("graphicsmagick", "1.3.45")
    @test Repology.identify_upstream("https://sourceforge.net/projects/libpng/files/libpng16/1.6.54/libpng-1.6.54.tar.gz", "") == ("libpng", "1.6.54")

    @test_broken Repology.identify_upstream("https://github.com/libexpat/libexpat/releases/download/R_2_2_7/expat-2.2.7.tar.xz", "") == ("expat", "2.2.7")
    @test_broken Repology.identify_upstream("https://github.com/Singular/Singular/releases/download/Release-4-4-1p5/singular-4.4.1p5.tar.gz", "") == ("singular", "4.4.1p5")
end
