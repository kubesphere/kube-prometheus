local k = import 'ksonnet/ksonnet.beta.4/k.libsonnet';
local kp =
  (import 'kube-prometheus/kube-prometheus.libsonnet') +
//(import 'kube-prometheus/kube-prometheus-static-etcd.libsonnet') +
//(import 'kube-prometheus/ksm-autoscaler/ksm-autoscaler.libsonnet') +
  (import 'kube-prometheus/kube-prometheus-strip-limits.libsonnet') +
  (import 'kube-prometheus/kube-prometheus-anti-affinity.libsonnet')
  {
    _config+:: {
      namespace: 'kubesphere-monitoring-system',

      versions+:: {
        prometheus: "v2.11.0",
        alertmanager: "v0.18.0",
        kubeStateMetrics: "v1.8.0",
        kubeRbacProxy: "v0.4.1",
        addonResizer: "1.8.4",
        nodeExporter: "ks-v0.18.1", 
        prometheusOperator: 'v0.33.0',
        configmapReloader: 'v0.0.1',
        prometheusConfigReloader: 'v0.33.0',
        prometheusAdapter: 'v0.4.1',
        thanos: "v0.7.0",
        clusterVerticalAutoscaler: "1.0.0"
      },

      imageRepos+:: {
        prometheus: "kubesphere/prometheus",
        alertmanager: "kubesphere/alertmanager",
        kubeStateMetrics: "kubesphere/kube-state-metrics",
        kubeRbacProxy: "kubesphere/kube-rbac-proxy",
        addonResizer: "kubesphere/addon-resizer",
        nodeExporter: "kubesphere/node-exporter",
        prometheusOperator: "kubesphere/prometheus-operator",
        configmapReloader: 'kubesphere/configmap-reload',
        prometheusConfigReloader: 'kubesphere/prometheus-config-reloader',
        prometheusAdapter: 'kubesphere/k8s-prometheus-adapter-amd64',
        thanos: 'kubesphere/thanos',
        clusterVerticalAutoscaler: 'gcr.io/google_containers/cluster-proportional-vertical-autoscaler-amd64'
      },

      prometheus+:: {
        retention: '7d',
        scrapeInterval: '1m',
        namespaces: ['default', 'kube-system', 'kubesphere-devops-system', 'istio-system', $._config.namespace],
        serviceMonitorSelector: {matchExpressions: [{key: 'k8s-app', operator: 'In', values: ['kube-state-metrics', 'node-exporter', 'kubelet', 'prometheus', 'etcd', 'coredns', 'apiserver', 'kube-scheduler', 'kube-controller-manager', 's2i-operator']}]},
        storage: {
          volumeClaimTemplate: {
            spec: {
              resources: {
                requests: {
                  storage: '20Gi',
                },
              },
            },
          },
        },
        query: {
          maxConcurrency: 1000 
        },
        tolerations: [
          {
            key: 'dedicated',
            operator: 'Equal',
            value: 'monitoring',
            effect: 'NoSchedule',
          },
        ],
      },

      kubeStateMetrics+:: {
        scrapeInterval: '1m',
      },

//      etcd+:: {
//        ips: ['127.0.0.1'],
//        clientCA: importstr 'etcd-client-ca.crt',
//        clientKey: importstr 'etcd-client.key',
//        clientCert: importstr 'etcd-client.crt',
//        serverName: 'etcd.kube-system.svc.cluster.local',
//      },
    },

    alertmanager+:: {
      serviceMonitor+:
        {
          spec+: {
            endpoints: [
              {
                port: 'web',
                interval: '1m',
              },
            ],
          },
        },      
    }, 

    grafana+:: {
      serviceMonitor+:
        {
          spec+: {
            endpoints: [
              {
                port: 'http',
                interval: '1m',
              },
            ],
          },
        },      
    }, 
    kubeStateMetrics+:: {
      deployment:
        local deployment = k.apps.v1.deployment;
        local container = deployment.mixin.spec.template.spec.containersType;
        local volume = deployment.mixin.spec.template.spec.volumesType;
        local containerPort = container.portsType;
        local containerVolumeMount = container.volumeMountsType;
        local podSelector = deployment.mixin.spec.template.spec.selectorType;
  
        local podLabels = { app: 'kube-state-metrics' };
  
        local proxyClusterMetrics =
          container.new('kube-rbac-proxy-main', $._config.imageRepos.kubeRbacProxy + ':' + $._config.versions.kubeRbacProxy) +
          container.withArgs([
            '--logtostderr',
            '--secure-listen-address=:8443',
            '--tls-cipher-suites=' + std.join(',', $._config.tlsCipherSuites),
            '--upstream=http://127.0.0.1:8081/',
          ]) +
          container.withPorts(containerPort.newNamed(8443, 'https-main',)) +
          container.mixin.resources.withRequests($._config.resources['kube-rbac-proxy'].requests) +
          container.mixin.resources.withLimits($._config.resources['kube-rbac-proxy'].limits);
  
        local proxySelfMetrics =
          container.new('kube-rbac-proxy-self', $._config.imageRepos.kubeRbacProxy + ':' + $._config.versions.kubeRbacProxy) +
          container.withArgs([
            '--logtostderr',
            '--secure-listen-address=:9443',
            '--tls-cipher-suites=' + std.join(',', $._config.tlsCipherSuites),
            '--upstream=http://127.0.0.1:8082/',
          ]) +
          container.withPorts(containerPort.newNamed(9443, 'https-self',)) +
          container.mixin.resources.withRequests($._config.resources['kube-rbac-proxy'].requests) +
          container.mixin.resources.withLimits($._config.resources['kube-rbac-proxy'].limits);
  
        local kubeStateMetrics =
          container.new('kube-state-metrics', $._config.imageRepos.kubeStateMetrics + ':' + $._config.versions.kubeStateMetrics) +
          container.withArgs([
            '--host=127.0.0.1',
            '--port=8081',
            '--telemetry-host=127.0.0.1',
            '--telemetry-port=8082',
            '--metric-blacklist=kube_pod_container_status_.*terminated_reason,kube_.+_version,kube_.+_created,kube_deployment_(spec_paused|spec_strategy_rollingupdate_.+),kube_endpoint_(info|address_.+),kube_job_(info|complete|failed|owner|spec_.+|status_.+),kube_cronjob_(info|status_.+|spec_.+),kube_namespace_(status_phase),kube_persistentvolume_(info|status_.+|capacity_.+),kube_persistentvolumeclaim_(status_.+|resource_.+|access_.+),kube_secret_(type),kube_service_(spec_.+|status_.+),kube_ingress_(info|path|tls),kube_replicaset_(status_.+|spec_.+|owner),kube_poddisruptionbudget_status_.+,kube_replicationcontroller_.+,kube_node_(info|role|spec_.+|status_allocatable_.+),kube_.+_updated,kube_.+_generation,kube_.+_revision',
          ] + if $._config.kubeStateMetrics.collectors != '' then ['--collectors=' + $._config.kubeStateMetrics.collectors] else []) +
          container.mixin.resources.withRequests({ cpu: $._config.kubeStateMetrics.baseCPU, memory: $._config.kubeStateMetrics.baseMemory }) +
          container.mixin.resources.withLimits({});
  
        local c = [proxyClusterMetrics, proxySelfMetrics, kubeStateMetrics];
  
        deployment.new('kube-state-metrics', 1, c, podLabels) +
        deployment.mixin.metadata.withNamespace($._config.namespace) +
        deployment.mixin.metadata.withLabels(podLabels) +
        deployment.mixin.spec.selector.withMatchLabels(podLabels) +
        deployment.mixin.spec.template.spec.withNodeSelector({ 'kubernetes.io/os': 'linux' }) +
        deployment.mixin.spec.template.spec.securityContext.withRunAsNonRoot(true) +
        deployment.mixin.spec.template.spec.securityContext.withRunAsUser(65534) +
        deployment.mixin.spec.template.spec.withServiceAccountName('kube-state-metrics'),

      serviceMonitor+:
        {
          spec+: {
            endpoints: [
              {
                port: 'https-main',
                scheme: 'https',
                interval: $._config.kubeStateMetrics.scrapeInterval,
                scrapeTimeout: $._config.kubeStateMetrics.scrapeTimeout,
                honorLabels: true,
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                relabelings: [
                  {
                    regex: '(service|endpoint)',
                    action: 'labeldrop',
                  },
                ],
                tlsConfig: {
                  insecureSkipVerify: true,
                },
              },
              {
                port: 'https-self',
                scheme: 'https',
                interval: '1m',
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                tlsConfig: {
                  insecureSkipVerify: true,
                },
              },
            ],            
          },
        },      
    }, 

    nodeExporter+:: {
      serviceMonitor+:
        {
          spec+: {
            endpoints: [
              {
                port: 'https',
                scheme: 'https',
                interval: '1m',
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                relabelings: [
                  {
                    regex: '(service|endpoint)',
                    action: 'labeldrop',
                  },
                  {
                    action: 'replace',
                    regex: '(.*)',
                    replacement: '$1',
                    sourceLabels: ['__meta_kubernetes_pod_node_name'],
                    targetLabel: 'instance',
                  },
                ],
                tlsConfig: {
                  insecureSkipVerify: true,
                },
                metricRelabelings: [
                  {
                    sourceLabels: ['__name__'],
                    regex: 'node_cpu_.+|node_memory_Mem.+_bytes|node_memory_Cached_bytes|node_memory_Buffers_bytes|node_network_.+_bytes_total|node_disk_.+_completed_total|node_disk_.+_bytes_total|node_filesystem_files|node_filesystem_files_free|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_filesystem_free_bytes|node_load.+',
                    action: 'keep',
                  },
                ],
              },
            ],
          },
        },      
    }, 

    prometheus+:: {
      roleSpecificNamespaces:
        {
        },
      roleBindingSpecificNamespaces:
        {
        },
      clusterRole:
        local clusterRole = k.rbac.v1.clusterRole;
        local policyRule = clusterRole.rulesType;
  
        local nodeMetricsRule = policyRule.new() +
                                policyRule.withApiGroups(['']) +
                                policyRule.withResources([
                                  'nodes/metrics',
                                  'nodes',
                                  'services',
                                  'endpoints',
                                  'pods',
                                ]) +
                                policyRule.withVerbs(['get', 'list', 'watch']);
  
        local metricsRule = policyRule.new() +
                            policyRule.withNonResourceUrls('/metrics') +
                            policyRule.withVerbs(['get']);
  
        local rules = [nodeMetricsRule, metricsRule];
  
        clusterRole.new() +
        clusterRole.mixin.metadata.withName('prometheus-' + self.name) +
        clusterRole.withRules(rules),
      prometheus+:
        local statefulSet = k.apps.v1.statefulSet;
        local toleration = statefulSet.mixin.spec.template.spec.tolerationsType;
        local withTolerations() = {
          tolerations: [
            toleration.new() + (
            if std.objectHas(t, 'key') then toleration.withKey(t.key) else toleration) + (
            if std.objectHas(t, 'operator') then toleration.withOperator(t.operator) else toleration) + (
            if std.objectHas(t, 'value') then toleration.withValue(t.value) else toleration) + (
            if std.objectHas(t, 'effect') then toleration.withEffect(t.effect) else toleration),
            for t in $._config.prometheus.tolerations
          ],
        };
        {
          spec+: {
            retention: $._config.prometheus.retention,
            scrapeInterval: $._config.prometheus.scrapeInterval,
            storage: $._config.prometheus.storage,
            query: $._config.prometheus.query,
            //secrets: ['kube-etcd-client-certs'],
            serviceMonitorSelector: $._config.prometheus.serviceMonitorSelector,
            securityContext: {
              runAsUser: 0,
              runAsNonRoot: false,
              fsGroup: 0,
            },
            additionalScrapeConfigs: {
              name: 'additional-scrape-configs',
              key: 'prometheus-additional.yaml',
            },
          } + withTolerations(),
        },
      serviceMonitor+:
        {
          spec+: {
            endpoints: [
              {
                port: 'web',
                interval: '1m',
                relabelings: [
                  {
                    regex: '(service|endpoint)',
                    action: 'labeldrop',
                  },
                ],
              },
            ],
          },
        },
//      serviceMonitorEtcd+:
//        {
//          metadata+: {
//            namespace: 'kubesphere-monitoring-system',
//          },
//          spec+: {
//            endpoints: [
//              {
//                port: 'metrics',
//                interval: '1m',
//                scheme: 'https',
//                // Prometheus Operator (and Prometheus) allow us to specify a tlsConfig. This is required as most likely your etcd metrics end points is secure.
//                tlsConfig: {
//                  caFile: '/etc/prometheus/secrets/kube-etcd-client-certs/etcd-client-ca.crt',
//                  keyFile: '/etc/prometheus/secrets/kube-etcd-client-certs/etcd-client.key',
//                  certFile: '/etc/prometheus/secrets/kube-etcd-client-certs/etcd-client.crt',
//                  [if $._config.etcd.serverName != null then 'serverName']: $._config.etcd.serverName,
//                  [if $._config.etcd.insecureSkipVerify != null then 'insecureSkipVerify']: $._config.etcd.insecureSkipVerify,
//                },
//              },
//            ],
//          },
//        },
//      secretEtcdCerts: 
//        {
//
//        },
      serviceMonitorKubeScheduler+:
        {
          spec+: {
           endpoints: [
              {
                port: 'http-metrics',
                interval: '1m',
              },
            ],
          },
        },
      serviceMonitorKubelet+:
        {
          spec+: {
            endpoints: [
              {
                port: 'https-metrics',
                scheme: 'https',
                interval: '1m',
                honorLabels: true,
                tlsConfig: {
                  insecureSkipVerify: true,
                },
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                relabelings: [
                  {
                    regex: '(service|endpoint)',
                    action: 'labeldrop',
                  },
                ],
                metricRelabelings: [
                  // Drop unused metrics
                  {
                    sourceLabels: ['__name__'],
                    regex: 'kubelet_running_container_count|kubelet_running_pod_count|kubelet_volume_stats.*',
                    action: 'keep',
                  },
                ],
              },
              {
                port: 'https-metrics',
                scheme: 'https',
                path: '/metrics/cadvisor',
                interval: '1m',
                honorLabels: true,
                tlsConfig: {
                  insecureSkipVerify: true,
                },
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                relabelings: [
                  {
                    regex: '(service|endpoint)',
                    action: 'labeldrop',
                  },
                ],
                metricRelabelings: [
                  {
                    sourceLabels: ['__name__'],
                    regex: 'container_cpu_usage_seconds_total|container_memory_usage_bytes|container_memory_cache|container_network_.+_bytes_total|container_memory_working_set_bytes',
                    action: 'keep',
                  },
                ],
              },
            ],
          },
        },
      serviceMonitorKubeControllerManager+:
        {
          spec+: {
            endpoints: [
              {
                port: 'http-metrics',
                interval: '1m',
                metricRelabelings: [
                  {
                    sourceLabels: ['__name__'],
                    regex: 'up',
                    action: 'keep'
                  },
                ],
              },
            ],
          },
        },
      serviceMonitorApiserver+:
        {
          spec+: {
            endpoints: [
              {
                port: 'https',
                interval: '1m',
                scheme: 'https',
                tlsConfig: {
                  caFile: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                  serverName: 'kubernetes',
                },
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
                metricRelabelings: [
                  {
                    sourceLabels: ['__name__'],
                    regex: 'etcd_(debugging|disk|request|server).*',
                    action: 'drop',
                  },
                  {
                    sourceLabels: ['__name__'],
                    regex: 'apiserver_admission_controller_admission_latencies_seconds_.*',
                    action: 'drop',
                  },
                  {
                    sourceLabels: ['__name__'],
                    regex: 'apiserver_admission_step_admission_latencies_seconds_.*',
                    action: 'drop',
                  },
                ],
              },
            ],
          },
        },
      serviceMonitorCoreDNS+:
        {
          spec+: {
            selector+: {
              matchLabels+: {
                'k8s-app': 'coredns',
              },
            },
            endpoints: [
              {
                port: 'metrics',
                interval: '1m',
                bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              },
            ],
          },
        },    
      serviceMonitorS2IOperator+:
        {
          apiVersion: 'monitoring.coreos.com/v1',
          kind: 'ServiceMonitor',
          metadata: {
            name: 's2i-operator',
            namespace: $._config.namespace,
            labels: {
              'k8s-app': 's2i-operator',
            },
          },
          spec: {
            jobLabel: 'k8s-app',
            selector: {
              matchLabels: {
                'control-plane': 's2i-controller-manager',
                'app': 's2i-metrics',
              },
            },
            namespaceSelector: {
              matchNames: [
                'kubesphere-devops-system',
              ],
            },
            endpoints: [
              {
                port: 'http',
                interval: '1m',
                honorLabels: true,
                metricRelabelings: [
                  {
                    sourceLabels: ['__name__'],
                    regex: 's2i_s2ibuilder_created',
                    action: 'keep',
                  },
                ],
              },
            ],
          },
        },
      }, 
  };

local manifests =
  // Uncomment line below to enable vertical auto scaling of kube-state-metrics
  // { ['ksm-autoscaler-' + name]: kp.ksmAutoscaler[name] for name in std.objectFields(kp.ksmAutoscaler) } +
  { ['setup/0namespace-' + name]: kp.kubePrometheus[name] for name in std.objectFields(kp.kubePrometheus) } +
  {
    ['setup/prometheus-operator-' + name]: kp.prometheusOperator[name]
    for name in std.filter((function(name) name != 'serviceMonitor'), std.objectFields(kp.prometheusOperator))
  } +
  // serviceMonitor is separated so that it can be created after the CRDs are ready
  { 'prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
  { ['node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) } +
  { ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
  { ['alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
  { ['prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) } +
  { ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) } +
  { ['grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) };

local kustomizationResourceFile(name) = './manifests/' + name + '.yaml';
local kustomization = {
  apiVersion: 'kustomize.config.k8s.io/v1beta1',
  kind: 'Kustomization',
  resources: std.map(kustomizationResourceFile, std.objectFields(manifests)),
};

manifests {
  '../kustomization': kustomization,
}
