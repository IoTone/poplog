/* Jenkinsfile — CI for the pop11 Claude-skill tarballs.
 *
 * ONE machine checks the tree out: the builder. Every platform is then sent
 * a packed tree (tools/ci/pack-tree.sh — tracked files only, no .git), and
 * nothing but the builder ever talks to GitHub. A build node therefore
 * needs no SCM credential, no ssh key and no git at all, and does not
 * accumulate 61 MB of history to compile a tree that never reads it.
 *
 * Topology: a platform is either a Jenkins NODE or an SSH TARGET, and each
 * platform picks one.
 *
 *   node    — the agent runs on the machine; the tree goes out and the
 *             tarball comes back by stash/unstash, over the agent channel
 *             that is already connected and authenticated. Real
 *             per-platform logs, a persistent workspace (so the engine is
 *             reused instead of rebuilt from seed), and no dependence on
 *             one builder's ssh config.
 *   ssh     — the x86_64 builder ssh'es in (tools/ci/build-remote.sh),
 *             syncs the tracked tree by tar and copies the tarball back.
 *             The board needs no agent, no JVM and no inbound connection
 *             from the controller — just sshd, cc, make, curl and tar.
 *             This is what a cloud VM or a board too small for an agent
 *             gets. Same two scripts for the tree, so both routes deliver
 *             a byte-identical source directory.
 *
 * Per platform, the node wins if its *_NODE parameter is set, and the ssh
 * route is the fallback. Today: linux-x86_64 and linux-arm64 (the Pi 5,
 * node "dietpi5-kordshom") are nodes; riscv64 and macOS are ssh targets.
 * Both routes run the same two scripts, so a platform can move from one to
 * the other without the build changing underneath it.
 *
 * What it does
 *   Source:  checkout + tools/ci/pack-tree.sh, once, on the builder. The
 *            archive carries .ci-manifest and .ci-commit: the manifest lets
 *            a reused workspace drop sources the tree no longer has (plain
 *            tar is additive, and a stale pop/lib/*.p is still found by
 *            `uses` — this project's oldest bug shape), and the commit is
 *            how a platform with no .git still knows what it built.
 *   Probe:   tools/ci/probe-prereqs.sh — every tool and header the build
 *            and the smoke tests need, checked in seconds. A missing
 *            <sqlite3.h> otherwise surfaces an hour in, when the installer
 *            tries to compile the popsqlite shim.
 *   Package: tools/ci/build-and-verify.sh builds the engine (corepop seed
 *            -> make all) if the workspace doesn't already have one,
 *            packages the relocatable tarball, verifies its contents, and
 *            runs the real installer + a live session smoke test in a
 *            sandbox HOME.
 *   Collect: gathers every platform's tarball into dist/ on the builder
 *            and archives them.
 *   Publish: (opt-in via the PUBLISH parameter) regenerates
 *            SHA256SUMS.pop11-skill over dist/ and uploads to the GitHub
 *            release with --clobber.
 *
 * Jenkins-side setup (nothing machine-specific belongs in this file):
 *   - Builder node: one x86_64 Linux agent named "nix" (a node's name is
 *     also a label, which is what the agent directives pin to).
 *     Prerequisites: whatever probe-prereqs.sh asks for, plus ssh/scp for
 *     the ssh-route platforms. The gh CLI is needed only for PUBLISH.
 *   - arm64 node: "dietpi5-kordshom", a Raspberry Pi 5 running DietPi,
 *     agent connected outbound (remoting.jar, workDir ~/jenkins). A JDK for
 *     the agent, plus what probe-prereqs.sh asks for. No git, no GitHub
 *     credential, no .git directory. Clear its workspace to force a
 *     from-seed build, or set FORCE_ENGINE_REBUILD.
 *   - ssh targets: the builder's own ~/.ssh/config and keys decide what
 *     "riscv-cloud" means. Hostnames, IPs, ports and users stay on the
 *     builder, never in the repo; the REMOTE_* parameters take only the
 *     alias, optionally with a ":dir" suffix to reuse an existing tree on
 *     a board short of disk. An empty parameter skips that platform.
 *   - Credential: a GitHub token with release-assets write access, stored
 *     as a Jenkins "Secret text" credential with ID `github-release-token`.
 *     It is only ever exposed to the publish step via withCredentials and
 *     read by gh from the environment — never echoed, never a parameter.
 */
pipeline {
    /* The builder. Stages with their own `agent` run elsewhere; everything
     * else — Collect, Publish — happens here, and this is where dist/ ends
     * up. Pinned by name rather than by a label expression: there is
     * exactly one builder, and its ssh config/keys are what make the ssh
     * platforms reachable, so a second x86_64 node picking this job up
     * would fail at the first ssh stage. */
    agent { label 'nix' }
    options {
        /* No implicit per-stage checkout. The builder checks out once in
         * Source and every other platform is sent the packed tree, which
         * is what keeps SCM credentials off the nodes. */
        skipDefaultCheckout()
        timestamps()
        disableConcurrentBuilds()
        /* a from-seed riscv64 build is slow; this covers all platforms */
        timeout(time: 180, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    parameters {
        booleanParam(name: 'PUBLISH', defaultValue: false,
            description: 'Upload the tarballs + checksums to the GitHub release')
        string(name: 'RELEASE_TAG', defaultValue: 'v160200-skill',
            description: 'Release tag to upload assets to (publish only)')
        booleanParam(name: 'FORCE_ENGINE_REBUILD', defaultValue: false,
            description: 'Rebuild the Poplog engine even if the workspace has one')
        /* Jenkins node labels. Set => that platform builds natively on the
         * node and its REMOTE_* parameter is ignored. */
        string(name: 'ARM64_NODE', defaultValue: 'dietpi5-kordshom',
            description: 'Jenkins node for arm64 Linux; empty = fall back to REMOTE_ARM64 over ssh')
        /* ssh aliases as known to the builder; empty => skip that platform.
         * May carry a remote dir: "riscv-cloud:poplog" reuses an existing
         * tree, which matters on a board short of disk. */
        string(name: 'REMOTE_ARM64', defaultValue: '',
            description: 'ssh alias of an arm64 Linux board; used only when ARM64_NODE is empty')
        string(name: 'REMOTE_RISCV64', defaultValue: 'riscv-cloud',
            description: 'ssh alias of a riscv64 Linux host; empty = skip')
        string(name: 'REMOTE_MACOS', defaultValue: '',
            description: 'ssh alias of a macOS arm64 host; empty = skip')
        /* Deliberately empty by default and deliberately not an address in
         * the repo: set it on the job (or in a folder default) so the
         * notification target is Jenkins config, not a committed file. */
        string(name: 'MAIL_TO', defaultValue: '',
            description: 'Address to notify when the build is not SUCCESS; empty = no mail')
    }
    environment {
        FORCE_ENGINE_REBUILD = "${params.FORCE_ENGINE_REBUILD ? 1 : 0}"
    }
    stages {
        stage('Source') {
            steps {
                checkout scm
                sh 'sh tools/ci/pack-tree.sh poplog-src.tar.gz'
                /* The unpacker travels inside the archive, but stashing it
                 * alongside means a node needs nothing of its own to get
                 * started. */
                stash name: 'source',
                      includes: 'poplog-src.tar.gz,tools/ci/unpack-tree.sh'
            }
        }
        stage('Package') {
            parallel {
                stage('linux-x86_64') {
                    steps {
                        sh 'sh tools/ci/probe-prereqs.sh'
                        sh 'sh tools/ci/build-and-verify.sh dist'
                    }
                }
                stage('linux-arm64') {
                    /* beforeAgent, or declarative allocates the agent first
                     * and only then decides to skip -- and with ARM64_NODE
                     * empty, `label ""` means "any agent", so the skipped
                     * stage would claim an executor on the way past. */
                    when {
                        beforeAgent true
                        expression { params.ARM64_NODE?.trim() }
                    }
                    agent { label "${params.ARM64_NODE}" }
                    steps {
                        /* The workspace persists between builds, which is
                         * the point: target/pop/basepop11 survives and the
                         * engine is reused rather than re-seeded. unpack
                         * leaves build products alone and prunes only the
                         * sources this tree has dropped. */
                        unstash 'source'
                        sh 'sh tools/ci/unpack-tree.sh poplog-src.tar.gz'
                        sh 'sh tools/ci/probe-prereqs.sh'
                        sh 'sh tools/ci/build-and-verify.sh dist'
                        /* back to the builder for Collect: the two machines
                         * share no filesystem */
                        stash name: 'tarball-linux-arm64',
                              includes: 'dist/pop11-skill-linux-aarch64.tar.gz'
                    }
                }
                stage('linux-arm64 (ssh)') {
                    when {
                        expression {
                            !params.ARM64_NODE?.trim() && params.REMOTE_ARM64?.trim()
                        }
                    }
                    steps {
                        sh "sh tools/ci/build-remote.sh '${params.REMOTE_ARM64}' dist"
                    }
                }
                stage('linux-riscv64') {
                    when { expression { params.REMOTE_RISCV64?.trim() } }
                    steps {
                        sh "sh tools/ci/build-remote.sh '${params.REMOTE_RISCV64}' dist"
                    }
                }
                stage('macos-arm64') {
                    when { expression { params.REMOTE_MACOS?.trim() } }
                    steps {
                        sh "sh tools/ci/build-remote.sh '${params.REMOTE_MACOS}' dist"
                    }
                }
            }
        }
        stage('Collect') {
            steps {
                /* The ssh route already scp'd its tarball into dist/ here;
                 * a node route has to be unstashed. Only unstash a stash
                 * the run actually created — unstash of a missing name is an
                 * error, so it is conditional on the same parameter as the
                 * stage that made it. */
                script {
                    if (params.ARM64_NODE?.trim()) { unstash 'tarball-linux-arm64' }
                }
                sh 'ls -l dist/pop11-skill-*.tar.gz'
                archiveArtifacts artifacts: 'dist/pop11-skill-*.tar.gz',
                                 fingerprint: true
                /* One sizes table over every tarball, now that they are all
                 * in one directory (build-and-verify.sh prints only the
                 * platform it just built). */
                sh 'DIST="$PWD/dist" sh tools/release-sizes.sh --print || true'
            }
        }
        stage('Publish') {
            when { expression { params.PUBLISH } }
            steps {
                sh '''
                    cd dist
                    sha256sum pop11-skill-*.tar.gz > SHA256SUMS.pop11-skill
                    cat SHA256SUMS.pop11-skill
                '''
                withCredentials([string(credentialsId: 'github-release-token',
                                        variable: 'GH_TOKEN')]) {
                    sh '''
                        cd dist
                        gh release upload "$RELEASE_TAG" \
                            pop11-skill-*.tar.gz SHA256SUMS.pop11-skill \
                            --clobber -R IoTone/poplog
                        gh release view "$RELEASE_TAG" -R IoTone/poplog \
                            --json assets \
                            -q '.assets[] | .name + "  " + .updatedAt'
                    '''
                }
            }
        }
    }
    post {
        /* No cleanWs(), on purpose. The workspaces are load-bearing: a
         * node's target/pop/basepop11 is what makes the next build reuse
         * the engine instead of fetching a corepop seed and rebuilding
         * from scratch. Wipe a workspace by hand (or set
         * FORCE_ENGINE_REBUILD) when you actually want that. */
        unsuccessful {
            script {
                if (params.MAIL_TO?.trim()) {
                    mail to: params.MAIL_TO,
                         subject: "poplog CI ${currentBuild.currentResult}: " +
                                  "${env.JOB_NAME} #${env.BUILD_NUMBER}",
                         body: "A platform failed to build or verify.\n\n" +
                               "${env.BUILD_URL}\n"
                } else {
                    echo 'build not SUCCESS and MAIL_TO is empty -- notifying nobody'
                }
            }
        }
    }
}
