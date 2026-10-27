require_relative 'spec_helper'

describe 'mimir-alertmanager job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(RELEASE_DIR) }
  let(:job) { release.job('mimir-alertmanager') }
  let(:template) { job.template('data/configs.sh') }
  let(:spec) { Bosh::Template::Test::InstanceSpec.new(bootstrap: true) }

  let(:title) { '{{ template "sn.title" . }} {{ $labels.x }} 100%' }
  let(:am_config) do
    {
      'route' => { 'receiver' => 'slack', 'group_by' => ['alertname'] },
      'receivers' => [{ 'name' => 'slack', 'slack_configs' => [{ 'api_url' => 'https://hooks/s3cr$t', 'title' => title }] }],
      'inhibit_rules' => [],
      'templates' => ['*.tmpl'],
    }
  end
  let(:tmpl) { "{{ define \"sn.title\" }}[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}{{ end }}\n# 100% $x `y`\n" }

  def render(props)
    template.render({ 'mimir-alertmanager' => props }, spec: spec)
  end

  let(:props) do
    {
      'address' => 'https://mimir',
      'auth' => { 'user' => 'u', 'key' => 'k' },
      'configs' => {
        'management' => { 'tenant_id' => 'mgmt', 'config' => am_config, 'templates' => { 'sn.tmpl' => tmpl, 'a.tmpl' => 'A' } },
        'apps' => { 'tenant_id' => 'apps', 'mode' => 'delete', 'auth' => { 'key' => 'other' } },
        'off' => { 'enabled' => false },
      },
    }
  end

  it 'renders enabled configs sorted by id' do
    r = render(props)
    expect(bash(r, 'echo "${AM_ID[*]}|${AM_TENANT_ID[*]}|${AM_MODE[*]}"').strip).to eq('apps management|apps mgmt|delete load')
    expect(bash(r, 'echo "${AM_DISABLED[*]}"').strip).to eq('off')
    expect(bash(r, 'echo "${AM_KEY[*]}"').strip).to eq('other k')
  end

  it 'round-trips the config byte-for-byte (R4.1)' do
    r = render(props)
    expect(YAML.safe_load(b64decode_var(r, '${AM_CONFIG[1]}'))).to eq(am_config)
  end

  it 'accepts the config as a YAML string' do
    props['configs']['management']['config'] = YAML.dump(am_config)
    r = render(props)
    expect(YAML.safe_load(b64decode_var(r, '${AM_CONFIG[1]}'))).to eq(am_config)
  end

  it 'passes templates byte-for-byte, sorted by name' do
    r = render(props)
    expect(b64decode_var(r, '${AM_TEMPLATE_NAMES[1]}')).to eq("a.tmpl\nsn.tmpl")
    expect(b64decode_var(r, '${AM_TEMPLATES_1[0]}')).to eq('A')
    expect(b64decode_var(r, '${AM_TEMPLATES_1[1]}')).to eq(tmpl)
  end

  it 'fails on duplicated tenant' do
    props['configs']['apps']['tenant_id'] = 'mgmt'
    expect { render(props) }.to raise_error(/same tenant 'mgmt'/)
  end

  it 'fails without config in load mode' do
    props['configs']['management'].delete('config')
    expect { render(props) }.to raise_error(/must define 'config'/)
  end

  it 'fails on invalid mode' do
    props['configs']['apps']['mode'] = 'sync'
    expect { render(props) }.to raise_error(/mode 'sync'/)
  end

  it 'fails on invalid template names' do
    props['configs']['management']['templates'] = { '../x' => 'y' }
    expect { render(props) }.to raise_error(/invalid template name/)
  end

  it 'fails without tenant_id' do
    props['configs']['apps'].delete('tenant_id')
    expect { render(props) }.to raise_error(/non-empty 'tenant_id'/)
  end

  it 'fails when enabled without configs' do
    expect { render({ 'address' => 'x' }) }.to raise_error(/no 'configs'/)
  end

  it 'renders nothing when disabled' do
    r = render({ 'enabled' => false })
    expect(bash(r, 'echo "${#AM_ID[@]}"').strip).to eq('0')
  end
end
