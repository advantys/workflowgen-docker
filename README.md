# WorkflowGen for Docker
This repository contains the Dockerfiles used for the WorkflowGen image. You can
find the image and a quick documentation on [Docker Hub](https://hub.docker.com/r/advantys/workflowgen).
This repository is designed for documentation purposes. It provides information
on how WorkflowGen is set up inside specific images and how it is configured at
runtime.

You can get started on the setup by visiting the Dockerfile for a specific version
of WorkflowGen and get started on the configuration at runtime by visiting the
`docker-entrypoint.ps1` script for a specific version of WorkflowGen.

# Content of this repository
This repository contains scripts for the pipeline build of this image as well as
all the needed resources to build the desired WorkflowGen image at a specific
version available in this repository.

**Pipeline scripts**

* azure-pipelines.yml

    Build definition file for the pipeline.

* update.ps1

    Update script for new versions. It takes template files specified when calling
    the script to produce a new version or update an existing one in this
    repository.

* scripts folder

    Contains multiple scripts for the pipeline build.

## WorkflowGen version folders
Those folders contains all of the files necessary to build the Docker image of
WorkflowGen for a specific version. For example, the 7.15 folder has the
following structure:

```
7.15
    windows
        windowsservercore-ltsc2016
            Dockerfile
            onbuild
                Dockerfile
        windowsservercore-ltsc2019
            Dockerfile
            onbuild
                Dockerfile
```

The `windows` folder indicates the platform of the files underneath. The
`windowsservercore-<version>` folders represent the base image currently supported
on the platform. The `onbuild` folder represents a variant of the image. The
main image files are located in the folder that represents the base image.

Over time, there will be more versions of WorkflowGen, more base images and
more platforms available.

# Build a specific version
## Release alias policy

The updater accepts an explicit publication policy. For a version-only evaluation
release in a new minor line, use:

```powershell
./update.ps1 -ToVersion 10.6.0 -TemplatesPath <WorkflowGen-Docker-templates> -PromoteFloatingTags false
```

This preserves the existing stable owners of `latest`, major and minor aliases.
The generated matrix records `WFGEN_PROMOTE_FLOATING_TAGS: false` for both Windows
platforms. The publisher emits only these tags for the example release:

- `10.6.0` and `10.6.0-onbuild` (LTSC 2019).
- `10.6.0-win-ltsc2019` and `10.6.0-win-ltsc2019-onbuild`.
- `10.6.0-win-ltsc2022` and `10.6.0-win-ltsc2022-onbuild`.

When a later release is approved as stable, select promotion explicitly:

```powershell
./update.ps1 -ToVersion 10.6.1 -TemplatesPath <WorkflowGen-Docker-templates> -PromoteFloatingTags true
```

Eligible stable aliases then move using the normal version ordering. In the
updater's alias selection, version-only entries do not prevent an intervening
stable backport from updating its eligible aliases. The default is `true` for
compatibility with existing release callers; existing matrix entries without
the policy retain their stable behavior.

For a complete 10.5.x application publication, the WorkflowGen maintenance branch
must also include the reviewed release-policy shared-builder compatibility update in
`build/docker/workflowgen/install-official-security-builder.ps1`, its matching
fixture and compatibility tests, including recognition of both exact 10.5/10.6
managed dispatches. A branch created from the older 10.5 source
without that update rejects this shared builder before staging. The offline
updater test covers alias selection, not that complete maintenance-release path;
do not bypass the managed builder's source-integrity guard.

The WorkflowGen production export installs its managed publisher for 10.5 and
10.6. It verifies the application and ONBUILD images offline before any tag or
push, while the explicit release policy still controls stable alias promotion.

Each minor line has one mutable build context. Version-only mode therefore refuses
to replace an existing stable minor context, and numeric downgrades within a minor
remain rejected. The existing V10.5 managed security builder is unchanged;
version-only mode cannot bypass it and fails before Docker is invoked.

Validate the updater and publisher offline with
`./scripts/tests/test-release-tag-policy.ps1`. Its temporary fixtures and mocked
Docker function do not build, tag or push real images.

## Prerequisites

* You need Docker installed on your machine in order to build an image.

    **For Windows 10**

    Follow the instructions in the [Docker for Windows documentation page](https://docs.docker.com/docker-for-windows/).

    **For Windows Server**

    Follow the instructions in the [Docker Enterprise Edition documentation page](https://docs.docker.com/install/windows/docker-ee/).

    To verify that Docker is installed correctly, run the following command:
    ```powershell
    docker version
    ```

## Building
To build a specific version of WorkflowGen, open PowerShell and go to the desired
version, platform, and base image folder. For example, if you are on Windows Server 2019
and want to build the latest 7.15 version of WorkflowGen (7.15.5), go to the `7.15\windows\windowsservercore-ltsc2019`
folder and execute the following command:

```powershell
docker build -t advantys/workflowgen:7.15.5-win-ltsc2019 .
```

To build the ONBUILD variant of the image, go to the `7.15\windows\windowsservercore-ltsc2019\onbuild`
and execute the following command:

```powershell
docker build -t advantys/workflowgen:7.15.5-win-ltsc2019-onbuild .
```

You should now have two Docker images of WorkflowGen in your list of images. To
get the images that are on your machine, execute `docker image ls`.
