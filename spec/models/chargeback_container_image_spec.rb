RSpec.describe ChargebackContainerImage do
  include Spec::Support::ChargebackHelper

  let(:base_options) { {:interval_size => 2, :end_interval_offset => 0, :ext_options => {:tz => 'UTC'} } }
  let(:hourly_rate)       { 0.01 }
  let(:count_hourly_rate) { 1.00 }
  let(:starting_date) { Time.parse('2012-09-01 23:59:59Z').utc }
  let(:ts) { starting_date.in_time_zone(Metric::Helper.get_time_zone(options[:ext_options])) }
  let(:report_run_time) { month_end }
  let(:month_beginning) { ts.beginning_of_month.utc }
  let(:month_end) { ts.end_of_month.utc }
  let(:hours_in_month) { Time.days_in_month(month_beginning.month, month_beginning.year) * 24 }
  let(:ems) { FactoryBot.create(:ems_openshift) }

  let(:hourly_variable_tier_rate) { {:variable_rate => hourly_rate.to_s} }
  let(:count_hourly_variable_tier_rate) { {:variable_rate => count_hourly_rate.to_s} }

  let(:detail_params) do
    {
      :chargeback_rate_detail_fixed_compute_cost  => {:tiers => [hourly_variable_tier_rate]},
      :chargeback_rate_detail_cpu_cores_allocated => {:tiers => [count_hourly_variable_tier_rate]},
      :chargeback_rate_detail_memory_allocated    => {:tiers => [hourly_variable_tier_rate]}
    }
  end

  let!(:chargeback_rate) do
    FactoryBot.create(:chargeback_rate, :detail_params => detail_params)
  end

  let(:metric_rollup_params) { {:parent_ems_id => ems.id, :tag_names => ""} }

  before do
    MiqRegion.seed
    ChargebackRateDetailMeasure.seed
    ChargeableField.seed
    MiqEnterprise.seed

    EvmSpecHelper.local_miq_server
    @node = FactoryBot.create(:container_node, :name => "node")
    @image = FactoryBot.create(:container_image, :ext_management_system => ems)
    @label = FactoryBot.build(:custom_attribute, :name => "version/1.2/_label-1", :value => "test/1.0.0  rc_2", :section => 'docker_labels')
    @project = FactoryBot.create(:container_project, :name => "my project", :ext_management_system => ems)
    @group = FactoryBot.create(:container_group, :ext_management_system => ems, :container_project => @project,
                                :container_node => @node)
    @container = FactoryBot.create(:kubernetes_container, :container_group => @group, :container_image => @image,
                                    :limit_memory_bytes => 1.megabytes, :limit_cpu_cores => 1.0)
    cat = FactoryBot.create(:classification, :description => "Environment", :name => "environment", :single_value => true, :show => true)
    c = FactoryBot.create(:classification, :name => "prod", :description => "Production", :parent_id => cat.id)
    ChargebackRate.set_assignments(:compute, [{ :cb_rate => chargeback_rate, :tag => [c, "container_image"] }])

    @tag = c.tag
    @project.tag_with(@tag.name, :ns => '*')
    @image.tag_with(@tag.name, :ns => '*')

    Timecop.travel(report_run_time)
  end

  after do
    Timecop.return
  end

  context "Daily" do
    let(:hours_in_day) { 24 }
    let(:options) { base_options.merge(:interval => 'daily', :entity_id => @image.id, :tag => nil) }
    let(:start_time)  { report_run_time - 17.hours }
    let(:finish_time) { report_run_time - 14.hours }

    before do
      add_metric_rollups_for(@image, month_beginning...month_end, 12.hours, metric_rollup_params)

      Range.new(start_time, finish_time, true).step_value(1.hour).each do |t|
        @container.vim_performance_states << FactoryBot.create(:vim_performance_state,
                                                               :timestamp       => t,
                                                               :image_tag_names => "environment/prod")
      end

      Range.new(start_time, finish_time, true).step_value(1.hour).each do |t|
        @image.vim_performance_states << FactoryBot.create(:vim_performance_state,
                                                           :timestamp       => t,
                                                           :image_tag_names => "environment/prod")
      end
    end

    subject { ChargebackContainerImage.build_results_for_report_ChargebackContainerImage(options).first.first }

    context 'when first metric rollup has tag_names=nil' do
      before do
        @image.metric_rollups.first.update(:tag_names => nil)
      end

      it "fixed_compute" do
        expect(subject.fixed_compute_1_cost).to eq(hourly_rate * hours_in_day)
      end
    end

    it "fixed_compute" do
      expect(subject.fixed_compute_1_cost).to eq(hourly_rate * hours_in_day)
    end

    it "allocated fields" do
      expect(subject.cpu_cores_allocated_cost).to eq(@image.containers.first.limit_cpu_cores * count_hourly_rate * hours_in_day)
      expect(subject.cpu_cores_allocated_metric).to eq(@image.containers.first.limit_cpu_cores)
      expect(subject.cpu_cores_allocated_cost).to eq(@image.containers.first.limit_memory_bytes / 1.megabytes * count_hourly_rate * hours_in_day)
      expect(subject.cpu_cores_allocated_metric).to eq(@image.containers.first.limit_memory_bytes / 1.megabytes)
    end
  end

  context "Monthly" do
    let(:options) { base_options.merge(:interval => 'monthly', :entity_id => @image.id, :tag => nil) }
    before do
      add_metric_rollups_for(@image, month_beginning...month_end, 12.hours, metric_rollup_params)

      Range.new(month_beginning, month_end, true).step_value(12.hours).each do |time|
        @container.vim_performance_states << FactoryBot.create(:vim_performance_state,
                                                               :timestamp       => time,
                                                               :image_tag_names => "environment/prod")
      end
    end

    subject { ChargebackContainerImage.build_results_for_report_ChargebackContainerImage(options).first.first }

    it "fixed_compute" do
      # .to be_within(0.01) is used since theres a float error here
      expect(subject.fixed_compute_1_cost).to be_within(0.01).of(hourly_rate * hours_in_month)
    end

    it "allocated fields" do
      expect(subject.cpu_cores_allocated_cost).to eq(@image.limit_cpu_cores * count_hourly_rate * hours_in_month)
      expect(subject.cpu_cores_allocated_metric).to eq(@image.limit_cpu_cores)
      expect(subject.cpu_cores_allocated_cost).to eq(@image.limit_memory_bytes / 1.megabytes * count_hourly_rate * hours_in_month)
      expect(subject.cpu_cores_allocated_metric).to eq(@image.limit_memory_bytes / 1.megabytes)
    end
  end

  context "Label" do
    let(:options) { base_options.merge(:interval => 'monthly', :entity_id => @image.id, :tag => nil) }
    before do
      @image.docker_labels << @label
      @image.save
      ChargebackRate.set_assignments(:compute, [{ :cb_rate => chargeback_rate, :label => [@label, "container_image"] }])

      add_metric_rollups_for(@image, month_beginning...month_end, 12.hours, metric_rollup_params)

      Range.new(month_beginning, month_end, true).step_value(12.hours).each do |time|
        @image.vim_performance_states << FactoryBot.create(:vim_performance_state,
                                                           :timestamp       => time,
                                                           :image_tag_names => "")
      end
    end

    subject { ChargebackContainerImage.build_results_for_report_ChargebackContainerImage(options).first.first }

    it "fixed_compute" do
      # .to be_within(0.01) is used since theres a float err here
      expect(subject.fixed_compute_1_cost).to be_within(0.01).of(hourly_rate * hours_in_month)
    end
  end

  context "Tag" do
    context "Group by multiple tag categories" do
      let(:options) { base_options.merge(:tag => [accounting_tag.name, cost_center_001_tag.name], :interval => 'monthly', :groupby_tag => %w[department cc]) }

      let(:department_tag_category)  { FactoryBot.create(:classification_department_with_tags) }
      let(:accounting_tag)           { department_tag_category.entries.find_by(:description => "Accounting").tag }
      let(:financial_services_tag)   { department_tag_category.entries.find_by(:description => "Financial Services").tag }

      let(:cost_center_tag_category) { FactoryBot.create(:classification_cost_center_with_tags) }
      let(:cost_center_001_tag)      { cost_center_tag_category.entries.find_by(:description => "Cost Center 001").tag }

      let(:production_tag)           { @tag }

      let(:images) do
        FactoryBot.create_list(:container_image, 5, :created_on => month_beginning) do |image, i|
          image.name = "test_image_#{i}"
        end
      end

      let(:rate_assignment_options) { {:cb_rate => chargeback_rate, :object => MiqEnterprise.first } }

      before do
        ChargebackRate.set_assignments(:compute, [rate_assignment_options])

        # category Department
        department_tag_category.entries.find_by(:description => "Accounting").tag.name

        images[0].tag_with(accounting_tag.name, :ns => '*')
        images[1].tag_with(accounting_tag.name, :ns => '*')
        images[2].tag_with(financial_services_tag.name, :ns => '*')

        # category Cost Center
        images[3].tag_with(cost_center_001_tag.name, :ns => '*')

        # category Environment
        images[4].tag_with(production_tag.name, :ns => '*')

        images.each do |image|
          add_metric_rollups_for(image, month_beginning...month_end, 12.hours, metric_rollup_params)
        end
      end

      subject { described_class.build_results_for_report_ChargebackContainerImage(options).first }

      let(:accounting_result_part)      { subject.detect { |x| x.tag_name == "Accounting" } }
      let(:cost_center_001_result_part) { subject.detect { |x| x.tag_name == "Cost Center 001" } }
      let(:production_result_part)      { subject.detect { |x| x.tag_name == "<Empty>" } }

      it "generates results for multiple tags categories" do
        expect(accounting_result_part.cpu_cores_allocated_cost).to be_within(0.01).of(2 * cost_center_001_result_part.cpu_cores_allocated_cost)
        expect(accounting_result_part.cpu_cores_allocated_metric).to be_within(0.01).of(2 * cost_center_001_result_part.cpu_cores_allocated_metric)

        expect(accounting_result_part.memory_allocated_metric).to be_within(0.01).of(2 * cost_center_001_result_part.memory_allocated_metric)
        expect(accounting_result_part.memory_allocated_cost).to be_within(0.01).of(2 * cost_center_001_result_part.memory_allocated_cost)

        expect(accounting_result_part.fixed_compute_metric).to be_within(0.01).of(cost_center_001_result_part.fixed_compute_metric)

        first_image = images[0].metric_rollups.sum(&:derived_vm_numvcpus) / images[0].metric_rollups.count
        second_image = images[1].metric_rollups.sum(&:derived_vm_numvcpus) / images[1].metric_rollups.count
        cpu_count = first_image + second_image

        expect(accounting_result_part.cpu_cores_allocated_metric).to eq(cpu_count)
        expect(accounting_result_part.cpu_cores_allocated_cost).to eq(cpu_count * count_hourly_rate * hours_in_month)

        expect(production_result_part).to be_nil
      end
    end
  end
end
