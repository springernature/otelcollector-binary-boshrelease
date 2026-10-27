require_relative 'spec_helper'

describe 'mimir-rules job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(RELEASE_DIR) }
  let(:job) { release.job('mimir-rules') }
  let(:template) { job.template('data/rulesets.sh') }
  let(:spec) { Bosh::Template::Test::InstanceSpec.new(bootstrap: true) }

  let(:annotation) { '{{ $labels.instance }} at {{ $value | humanizePercentage }}' }
  let(:alert_group) do
    {
      'name' => 'bosh',
      'interval' => '1m',
      'source_tenants' => %w(a b),
      'rules' => [{
        'alert' => 'High: 100%',
        'expr' => 'up{job="x"} == 0',
        'for' => '5m',
        'keep_firing_for' => '10m',
        'labels' => { 'severity' => 'critical' },
        'annotations' => { 'summary' => annotation, 'weird' => "a: 'b' # c \"d\" %s $HOME `x`" },
      }],
    }
  end
  let(:record_group) { { 'name' => 'rec', 'rules' => [{ 'record' => 'job:up:sum', 'expr' => 'sum by (job) (up)' }] } }
  let(:base) { { 'address' => 'https://mimir', 'tenant_id' => 'mgmt' } }

  def render(props)
    template.render({ 'mimir-rules' => props }, spec: spec)
  end

  def decoded_rules(rendered, index)
    YAML.safe_load(b64decode_var(rendered, "${RS_CONTENT[#{index}]}"))
  end

  describe 'rulesets' do
    let(:props) do
      base.merge('sync_mode' => 'sync', 'auth' => { 'user' => 'u', 'key' => 'top' },
                 'rulesets' => {
                   'recording' => { 'namespace' => 'rec-ns', 'groups' => [record_group] },
                   'alerts-bosh' => { 'namespace' => 'alerts-ns', 'tenant_id' => 'other', 'sync_mode' => 'load',
                                      'auth' => { 'key' => 's3cr$t' }, 'groups' => [alert_group] },
                   'off' => { 'enabled' => false },
                 })
    end

    it 'renders enabled rule sets sorted by id, with overrides and defaults' do
      r = render(props)
      expect(bash(r, 'echo "${RS_ID[*]}"').strip).to eq('alerts-bosh recording')
      expect(bash(r, 'echo "${RS_DISABLED[*]}"').strip).to eq('off')
      expect(bash(r, 'echo "${RS_NAMESPACE[*]}"').strip).to eq('alerts-ns rec-ns')
      expect(bash(r, 'echo "${RS_TENANT_ID[*]}"').strip).to eq('other mgmt')
      expect(bash(r, 'echo "${RS_SYNC_MODE[*]}"').strip).to eq('load sync')
      expect(bash(r, 'echo "${RS_USER[*]}"').strip).to eq('u u')
      expect(bash(r, 'echo "${RS_KEY[0]}|${RS_KEY[1]}"').strip).to eq('s3cr$t|top')
    end

    it 'round-trips alert rules byte-for-byte (R4.1)' do
      r = render(props)
      rules = decoded_rules(r, 0)
      expect(rules['namespace']).to eq('alerts-ns')
      expect(rules['groups']).to eq([alert_group])
      expect(rules['groups'][0]['rules'][0]['annotations']['summary']).to eq(annotation)
    end

    it 'renders the group names for delete-groups' do
      r = render(props)
      expect(b64decode_var(r, '${RS_GROUPS[0]}')).to eq('bosh')
    end

    it 'allows empty groups (R4.3)' do
      r = render(base.merge('rulesets' => { 'x' => { 'namespace' => 'n', 'groups' => [{ 'name' => 'g', 'rules' => [] }] } }))
      expect(decoded_rules(r, 0)['groups']).to eq([{ 'name' => 'g', 'rules' => [] }])
    end

    it 'fails without namespace' do
      expect { render(base.merge('rulesets' => { 'x' => { 'groups' => [] } })) }.to raise_error(/non-empty 'namespace'/)
    end

    it 'fails without groups' do
      expect { render(base.merge('rulesets' => { 'x' => { 'namespace' => 'n' } })) }.to raise_error(/'groups' array/)
    end

    it 'fails on duplicated (address, tenant, namespace)' do
      rs = { 'a' => { 'namespace' => 'n', 'groups' => [] }, 'b' => { 'namespace' => 'n', 'groups' => [] } }
      expect { render(base.merge('rulesets' => rs)) }.to raise_error(/same namespace 'n'/)
    end

    it 'allows the same namespace in different tenants' do
      rs = { 'a' => { 'namespace' => 'n', 'groups' => [] }, 'b' => { 'namespace' => 'n', 'tenant_id' => 't2', 'groups' => [] } }
      expect { render(base.merge('rulesets' => rs)) }.not_to raise_error
    end

    it 'ignores validation of disabled rule sets' do
      rs = { 'a' => { 'namespace' => 'n', 'groups' => [] }, 'b' => { 'enabled' => false } }
      expect { render(base.merge('rulesets' => rs)) }.not_to raise_error
    end

    it 'fails on invalid sync_mode' do
      rs = { 'a' => { 'namespace' => 'n', 'sync_mode' => 'nope', 'groups' => [] } }
      expect { render(base.merge('rulesets' => rs)) }.to raise_error(/sync_mode 'nope'/)
    end

    it 'fails without tenant_id' do
      rs = { 'a' => { 'namespace' => 'n', 'groups' => [] } }
      expect { render({ 'address' => 'x', 'rulesets' => rs }) }.to raise_error(/no 'tenant_id'/)
    end

    it 'fails on invalid ids' do
      rs = { '../x' => { 'namespace' => 'n', 'groups' => [] } }
      expect { render(base.merge('rulesets' => rs)) }.to raise_error(/invalid rule set id/)
    end
  end

  describe 'backwards compatibility (v4.2.0 rules)' do
    let(:legacy) { "namespace: legacy\ngroups:\n- name: g\n  rules:\n  - record: a:b\n    expr: sum(up)\n" }

    it 'treats rules as rule set default' do
      r = render(base.merge('rules' => legacy))
      expect(bash(r, 'echo "${RS_ID[*]}|${RS_NAMESPACE[*]}|${RS_SYNC_MODE[*]}"').strip).to eq('default|legacy|load')
      expect(decoded_rules(r, 0)).to eq(YAML.safe_load(legacy))
    end

    it 'combines rules with other rule sets' do
      r = render(base.merge('rules' => legacy, 'rulesets' => { 'zz' => { 'namespace' => 'z', 'groups' => [] } }))
      expect(bash(r, 'echo "${RS_ID[*]}"').strip).to eq('default zz')
    end

    it 'fails when rules and rulesets.default are both set' do
      expect do
        render(base.merge('rules' => legacy, 'rulesets' => { 'default' => { 'namespace' => 'z', 'groups' => [] } }))
      end.to raise_error(/both set/)
    end

    it 'fails when enabled and nothing is defined' do
      expect { render(base) }.to raise_error(/neither 'rules' nor 'rulesets'/)
    end

    it 'renders nothing when disabled' do
      r = render({ 'enabled' => false })
      expect(bash(r, 'echo "${#RS_ID[@]}"').strip).to eq('0')
    end
  end
end
