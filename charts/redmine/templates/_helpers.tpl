{{- define "redmine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redmine.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "redmine.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redmine.labels" -}}
helm.sh/chart: {{ include "redmine.chart" . }}
{{ include "redmine.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redmine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redmine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redmine.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "redmine.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "redmine.secretKeyBaseSecretName" -}}
{{- default (include "redmine.fullname" .) .Values.secretKeyBase.existingSecret -}}
{{- end -}}

{{- define "redmine.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{- define "redmine.persistenceVolumeName" -}}
{{- printf "data-%s" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redmine.persistenceClaimName" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $config := .config -}}
{{- if $config.existingClaim -}}
{{- $config.existingClaim -}}
{{- else -}}
{{- printf "%s-%s" (include "redmine.fullname" $root) $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "redmine.databasePort" -}}
{{- if .Values.database.port -}}
{{- .Values.database.port -}}
{{- else if eq .Values.database.type "postgresql" -}}
5432
{{- else if eq .Values.database.type "mysql" -}}
3306
{{- else if eq .Values.database.type "sqlserver" -}}
1433
{{- end -}}
{{- end -}}

{{- define "redmine.databaseEnv" -}}
{{- if ne .Values.database.type "sqlite" }}
- name: {{ if eq .Values.database.type "postgresql" }}REDMINE_DB_POSTGRES{{ else if eq .Values.database.type "mysql" }}REDMINE_DB_MYSQL{{ else }}REDMINE_DB_SQLSERVER{{ end }}
  value: {{ .Values.database.host | quote }}
- name: REDMINE_DB_PORT
  value: {{ include "redmine.databasePort" . | quote }}
- name: REDMINE_DB_DATABASE
  value: {{ .Values.database.name | quote }}
- name: REDMINE_DB_USERNAME
  value: {{ .Values.database.username | quote }}
- name: REDMINE_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.passwordKey }}
- name: REDMINE_DB_ENCODING
  value: {{ .Values.database.encoding | quote }}
{{- end }}
{{- end -}}

{{- define "redmine.commonEnv" -}}
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "redmine.secretKeyBaseSecretName" . }}
      key: {{ .Values.secretKeyBase.key }}
{{ include "redmine.databaseEnv" . }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "redmine.volumes" -}}
{{- range $name, $config := .Values.persistence }}
{{- if $config.enabled }}
- name: {{ include "redmine.persistenceVolumeName" $name }}
  persistentVolumeClaim:
    claimName: {{ include "redmine.persistenceClaimName" (dict "root" $ "name" $name "config" $config) }}
{{- end }}
{{- end }}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "redmine.volumeMounts" -}}
{{- range $name, $config := .Values.persistence }}
{{- if $config.enabled }}
{{- range $mount := $config.mounts }}
- name: {{ include "redmine.persistenceVolumeName" $name }}
  mountPath: {{ $mount.mountPath }}
  {{- with $mount.subPath }}
  subPath: {{ . }}
  {{- end }}
  readOnly: {{ default false $mount.readOnly }}
{{- end }}
{{- end }}
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "redmine.validate" -}}
{{- $dbTypes := list "sqlite" "postgresql" "mysql" "sqlserver" -}}
{{- if not (has .Values.database.type $dbTypes) -}}
{{- fail "database.type must be one of: sqlite, postgresql, mysql, sqlserver" -}}
{{- end -}}
{{- $migrationModes := list "startup" "job" "disabled" -}}
{{- if not (has .Values.migrations.mode $migrationModes) -}}
{{- fail "migrations.mode must be one of: startup, job, disabled" -}}
{{- end -}}
{{- if not .Values.secretKeyBase.key -}}
{{- fail "secretKeyBase.key is required" -}}
{{- end -}}
{{- if eq .Values.database.type "sqlite" -}}
  {{- if gt (int .Values.replicaCount) 1 -}}
  {{- fail "SQLite requires replicaCount=1" -}}
  {{- end -}}
  {{- if .Values.autoscaling.enabled -}}
  {{- fail "SQLite cannot be used with autoscaling" -}}
  {{- end -}}
  {{- if .Values.mailReceiver.enabled -}}
  {{- fail "mailReceiver requires an external database; concurrent SQLite access from another Pod is unsafe" -}}
  {{- end -}}
{{- else -}}
  {{- if not .Values.database.host -}}
  {{- fail "database.host is required for an external database" -}}
  {{- end -}}
  {{- if not .Values.database.existingSecret -}}
  {{- fail "database.existingSecret is required for an external database" -}}
  {{- end -}}
  {{- if not .Values.database.passwordKey -}}
  {{- fail "database.passwordKey is required for an external database" -}}
  {{- end -}}
{{- end -}}
{{- if and (eq .Values.migrations.mode "startup") (or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled) -}}
{{- fail "startup migrations require one fixed replica; use migrations.mode=job or disabled before scaling" -}}
{{- end -}}
{{- if and .Values.migrations.plugins (not (index .Values.persistence "plugins").enabled) -}}
{{- fail "migrations.plugins=true requires persistence.plugins.enabled=true" -}}
{{- end -}}
{{- if and (eq .Values.migrations.mode "job") (eq .Values.database.type "sqlite") (index .Values.persistence "sqlite").enabled (index .Values.persistence "sqlite").create -}}
{{- fail "SQLite migration Job requires an existing PVC because pre-install hooks run before chart-created PVCs" -}}
{{- end -}}
{{- if and .Values.mailReceiver.enabled (not .Values.mailReceiver.existingSecret) -}}
{{- fail "mailReceiver.existingSecret is required when mailReceiver is enabled" -}}
{{- end -}}
{{- if and .Values.mailReceiver.enabled (not .Values.mailReceiver.host) -}}
{{- fail "mailReceiver.host is required when mailReceiver is enabled" -}}
{{- end -}}
{{- if and .Values.mailReceiver.enabled (or (not .Values.mailReceiver.usernameKey) (not .Values.mailReceiver.passwordKey)) -}}
{{- fail "mailReceiver usernameKey and passwordKey are required when mailReceiver is enabled" -}}
{{- end -}}
{{- if and .Values.gatewayAPI.httpRoute.enabled (not .Values.gatewayAPI.httpRoute.parentRefs) -}}
{{- fail "gatewayAPI.httpRoute.parentRefs must contain at least one Gateway reference" -}}
{{- end -}}
{{- if and .Values.gatewayAPI.httpRoute.enabled (not .Values.gatewayAPI.httpRoute.rules) -}}
{{- fail "gatewayAPI.httpRoute.rules must contain at least one routing rule" -}}
{{- end -}}
{{- range $name, $config := .Values.persistence }}
  {{- if $config.enabled -}}
    {{- if and (not $config.existingClaim) (not $config.create) -}}
    {{- fail (printf "persistence.%s must set existingClaim or create=true" $name) -}}
    {{- end -}}
    {{- if and $config.create (not $config.size) -}}
    {{- fail (printf "persistence.%s.size is required when create=true" $name) -}}
    {{- end -}}
    {{- range $mount := $config.mounts -}}
      {{- if eq (trimSuffix "/" $mount.mountPath) "/usr/src/redmine/config" -}}
      {{- fail "mounting the complete /usr/src/redmine/config directory hides core routes and is forbidden" -}}
      {{- end -}}
      {{- if eq (trimSuffix "/" $mount.mountPath) "/usr/src/redmine/public" -}}
      {{- fail "mounting the complete /usr/src/redmine/public directory hides core assets and is forbidden" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $name := .Values.volumePermissions.persistenceNames -}}
  {{- $config := index $.Values.persistence $name -}}
  {{- if not $config -}}
  {{- fail (printf "volumePermissions persistence name %s does not exist" $name) -}}
  {{- end -}}
  {{- if and $.Values.volumePermissions.enabled (not $config.enabled) -}}
  {{- fail (printf "volumePermissions persistence name %s is disabled" $name) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
