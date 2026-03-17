#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const root = process.cwd();
const defaultsPath = path.join(root, 'class/defaults.yml');
const docsPath = path.join(root, 'docs/modules/ROOT/pages/references/parameters.adoc');

const manifestUrl = (tag) =>
  `https://raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/${tag}/manifests/vanilla/vsphere-csi-driver.yaml`;

const imageKeys = {
  csi_attacher: 'csi-attacher',
  csi_resizer: 'csi-resizer',
  driver: 'vsphere-csi-controller',
  syncer: 'vsphere-syncer',
  liveness_probe: 'liveness-probe',
  csi_provisioner: 'csi-provisioner',
  csi_snapshotter: 'csi-snapshotter',
  csi_node_driver_registrar: 'node-driver-registrar',
};

function parseImageRef(imageRef) {
  const slashIndex = imageRef.indexOf('/');
  const colonIndex = imageRef.lastIndexOf(':');

  if (slashIndex === -1 || colonIndex === -1 || colonIndex < slashIndex) {
    throw new Error(`Unable to parse image reference: ${imageRef}`);
  }

  return {
    registry: imageRef.slice(0, slashIndex),
    repository: imageRef.slice(slashIndex + 1, colonIndex),
    tag: imageRef.slice(colonIndex + 1),
  };
}

function extractDriverTag(defaultsText) {
  let inImages = false;
  let currentImage = null;

  for (const line of defaultsText.split('\n')) {
    if (line === '    images:') {
      inImages = true;
      currentImage = null;
      continue;
    }

    if (!inImages) {
      continue;
    }

    if (/^    [a-z_]+:\s*$/.test(line)) {
      break;
    }

    const imageMatch = line.match(/^      ([a-z_]+):\s*$/);
    if (imageMatch) {
      currentImage = imageMatch[1];
      continue;
    }

    if (currentImage === 'driver') {
      const tagMatch = line.match(/^        tag:\s+(\S+)\s*$/);
      if (tagMatch) {
        return tagMatch[1];
      }
    }
  }

  throw new Error('Unable to find parameters.vsphere_csi.images.driver.tag in class/defaults.yml');
}

function extractManifestImage(manifestText, containerName) {
  const lines = manifestText.split('\n');

  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i].trim() !== `- name: ${containerName}`) {
      continue;
    }

    for (let j = i + 1; j < lines.length; j += 1) {
      const imageMatch = lines[j].match(/^\s*image:\s+(\S+)\s*$/);
      if (imageMatch) {
        return parseImageRef(imageMatch[1]);
      }
    }
  }

  throw new Error(`Unable to find image for container ${containerName} in upstream manifest`);
}

function extractFeatureStates(manifestText) {
  const match = manifestText.match(
    /apiVersion:\s+v1\ndata:\n((?:  ".*": ".*"\n)+)kind:\s+ConfigMap\nmetadata:\n  name:\s+internal-feature-states\.csi\.vsphere\.vmware\.com\n  namespace:\s+vmware-system-csi/m
  );

  if (!match) {
    throw new Error('Unable to find internal feature states ConfigMap in upstream manifest');
  }

  return match[1]
    .trimEnd()
    .split('\n')
    .map((line) => {
      const stateMatch = line.match(/^  "([^"]+)": "([^"]+)"$/);
      if (!stateMatch) {
        throw new Error(`Unable to parse feature state line: ${line}`);
      }

      return {
        key: stateMatch[1],
        value: stateMatch[2],
      };
    });
}

function rewriteDefaults(defaultsText, images, featureStates) {
  const hasTrailingNewline = defaultsText.endsWith('\n');
  const lines = defaultsText.replace(/\n$/, '').split('\n');
  const out = [];
  let inFeatureStates = false;
  let inImages = false;
  let currentImage = null;

  for (const line of lines) {
    if (line === '    feature_states:') {
      out.push(line);
      for (const state of featureStates) {
        out.push(`      ${state.key}: "${state.value}"`);
      }
      inFeatureStates = true;
      continue;
    }

    if (inFeatureStates) {
      if (line === '    images:') {
        inFeatureStates = false;
        inImages = true;
        out.push('');
        out.push(line);
      }
      continue;
    }

    if (line === '    images:') {
      inImages = true;
      currentImage = null;
      out.push(line);
      continue;
    }

    if (inImages) {
      const sectionEnd = line.match(/^    [a-z_]+:\s*$/);
      if (sectionEnd) {
        inImages = false;
        currentImage = null;
        out.push(line);
        continue;
      }

      const imageMatch = line.match(/^      ([a-z_]+):\s*$/);
      if (imageMatch) {
        currentImage = imageMatch[1];
        out.push(line);
        continue;
      }

      if (currentImage && images[currentImage]) {
        const registryMatch = line.match(/^        registry:\s+(\S+)\s*$/);
        if (registryMatch) {
          out.push(`        registry: ${images[currentImage].registry}`);
          continue;
        }

        const repositoryMatch = line.match(/^        repository:\s+(\S+)\s*$/);
        if (repositoryMatch) {
          out.push(`        repository: ${images[currentImage].repository}`);
          continue;
        }

        const tagMatch = line.match(/^        tag:\s+(\S+)\s*$/);
        if (tagMatch) {
          out.push(`        tag: ${images[currentImage].tag}`);
          continue;
        }
      }
    }

    out.push(line);
  }

  return `${out.join('\n')}${hasTrailingNewline ? '\n' : ''}`;
}

function rewriteDocs(docsText, releaseTag) {
  return docsText
    .replace(
      /blob\/v[0-9.]+\/manifests\/vanilla\/vsphere-csi-driver\.yaml/g,
      `blob/${releaseTag}/manifests/vanilla/vsphere-csi-driver.yaml`
    )
    .replace(
      /raw\.githubusercontent\.com\/kubernetes-sigs\/vsphere-csi-driver\/v[0-9.]+\/manifests\/vanilla\/vsphere-csi-driver\.yaml/g,
      `raw.githubusercontent.com/kubernetes-sigs/vsphere-csi-driver/${releaseTag}/manifests/vanilla/vsphere-csi-driver.yaml`
    )
    .replace(
      /Defaults follow the upstream v[0-9.]+ Linux deployment manifest\./,
      `Defaults follow the upstream ${releaseTag} Linux deployment manifest.`
    );
}

async function main() {
  const defaultsText = await fs.readFile(defaultsPath, 'utf8');
  const docsText = await fs.readFile(docsPath, 'utf8');
  const releaseTag = extractDriverTag(defaultsText);

  const manifestText = execFileSync(
    'curl',
    ['-L', '--fail', '--silent', '--show-error', manifestUrl(releaseTag)],
    { encoding: 'utf8' }
  );

  const images = Object.fromEntries(
    Object.entries(imageKeys).map(([key, containerName]) => [key, extractManifestImage(manifestText, containerName)])
  );
  const featureStates = extractFeatureStates(manifestText);

  await fs.writeFile(defaultsPath, rewriteDefaults(defaultsText, images, featureStates));
  await fs.writeFile(docsPath, rewriteDocs(docsText, releaseTag));

  process.stdout.write(`Synced vSphere CSI defaults from upstream release ${releaseTag}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
