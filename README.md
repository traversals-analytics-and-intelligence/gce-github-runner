# gce-github-runner
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
[![Pre-commit](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml)
[![Test](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml)

Ephemeral GCE GitHub self-hosted runner.

## Usage

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - id: create-runner
        uses: traversals-analytics-and-intelligence/gce-github-runner@main
        with:
          token: ${{ secrets.GH_SA_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2204-lts

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
      - uses: traversals-analytics-and-intelligence/gce-github-runner@main
        with:
          command: stop
        if: always()
```

 * `create-runner` creates the GCE VM and registers the runner with unique label
 * `test` uses the runner, and destroys it as the last step

## Inputs

See inputs and descriptions [here](./action.yml).

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

## Working with GPU accelerators

#### ⚠️ Be aware that NVIDIA L4 and A100 GPUs use different machine types and cannot be attached to a normal VM. Please refer to https://cloud.google.com/compute/docs/gpus/ in case of uncertainty.

#### ⚠️ The current implementation is limited to Debian-based VM images.

### Supported VM images

 * Base images from projects `ubuntu-os-cloud` and `debian-cloud`
   * e.g. `ubuntu-2204-lts` or `debian-11`
 * Pre-built Deep Learning images from project `deeplearning-platform-release`
   * e.g. `common-cu113-ubuntu-2004`

In both cases, accelerator-related libraries like CUDA will be installed and can be used for further processing once the VM is provisioned. **Please note, that pre-built Deep Learning images tend to be faster in provisioning but older in terms of installed software.**

### Runner configuration

GPUs can be attached to the VM by using two additional arguments:
 * `accelerator_type`
 * `accelerator_count`

For example, we can extend the above workflow with these new arguments and some values taken from https://cloud.google.com/compute/docs/gpus/ or by consulting the command `gcloud compute accelerator-types list` to see which types and counts of accelerators GCP supports.

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - id: create-runner
        uses: traversals-analytics-and-intelligence/gce-github-runner@main
        with:
          token: ${{ secrets.GH_SA_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2204-lts
          accelerator_type: nvidia-tesla-t4
          accelerator_count: 1
```

In this example, we use one instance of an NVIDIA Tesla T4 GPU as our accelerator. Similarly, the type can be replaced with any other supported GPU.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
