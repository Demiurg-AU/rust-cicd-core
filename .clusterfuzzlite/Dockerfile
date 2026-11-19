# ClusterFuzzLite probe (ROADMAP O6a). Base image pinned by digest (index of :latest on 2026-11-19).
FROM gcr.io/oss-fuzz-base/base-builder-rust@sha256:3428d0a90b1e7efbe2ba947bd1d0c9a70594986b4b6553804547f1fb24cfc92f
COPY . $SRC/rust-cicd-core
WORKDIR $SRC/rust-cicd-core
COPY .clusterfuzzlite/build.sh $SRC/
