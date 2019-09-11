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
