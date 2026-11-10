{ pkgs, src }:
pkgs.applyPatches {
  name = "omp-compound-engineering";
  inherit src;
  patches = [ ./omp-ce-explicit-review.patch ];
}
