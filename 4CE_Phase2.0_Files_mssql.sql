--##############################################################################
--### 4CE Phase 2.0
--### Date: June 26, 2020
--### Database: Microsoft SQL Server
--### Data Model: i2b2
--### Created By: Griffin Weber (weber@hms.harvard.edu)
--##############################################################################


--*** THIS IS A DRAFT. 4CE SITES ARE NOT BEING ASKED TO RUN THIS SCRIPT YET. ***


--!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--!!! Run the 4CE Phase 1.1 script before you run this script.
--!!! Set all the obfuscation values in the Phase 1.1 #config table to 0.
--!!! This script uses the temp tables created by your 4CE Phase 1.1 script.
--!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


--------------------------------------------------------------------------------
-- General settings
--------------------------------------------------------------------------------
create table #config2 (
	replace_patient_num bit, -- Replace the patient_num with a unique random number
	save_as_columns bit, -- Save the data as tables with separate columns per field
	save_as_prefix varchar(50), -- Table name prefix when saving the data as tables
	output_as_columns bit, -- Return the data in tables with separate columns per field
	output_as_csv bit -- Return the data in tables with a single column containing comma separated values
)
insert into #config2
	select 
		1, -- replace_patient_num
		0, -- save_as_columns
		'dbo.Phase2', -- save_as_prefix (don't use "4CE" since it starts with a number)
		0, -- output_as_columns
		1  -- output_as_csv


--******************************************************************************
--******************************************************************************
--*** Create the Phase 2.0 patient level data tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Patient Summary: Dates, Outcomes, and Demographics
--------------------------------------------------------------------------------

create table #PatientSummary (
	siteid varchar(50) not null,
	patient_num int not null,
	admission_date date not null,
	days_since_admission int not null,
	last_discharge_date date not null,
	still_in_hospital int not null,
	severe_date date not null,
	severe int not null,
	death_date date not null,
	deceased int not null,
	sex varchar(50) not null,
	age_group varchar(50) not null,
	race varchar(50) not null,
	race_collected int not null
)

alter table #PatientSummary add primary key (patient_num)

insert into #PatientSummary (siteid, patient_num, admission_date, days_since_admission, last_discharge_date, still_in_hospital, severe_date, severe, death_date, deceased, sex, age_group, race, race_collected)
	select '', c.patient_num, c.admission_date, 
		datediff(dd,c.admission_date,GetDate()),
		(case when a.last_discharge_date = cast(GetDate() as date) then '1/1/1900' else a.last_discharge_date end),
		(case when a.last_discharge_date = cast(GetDate() as date) then 1 else 0 end),
		isnull(c.severe_date,'1/1/1900'),
		c.severe, 
		isnull(c.death_date,'1/1/1900'),
		(case when c.death_date is not null then 1 else 0 end),
		isnull(d.sex,'other'),
		isnull(d.age_group,'other'),
		(case when x.include_race=0 then 'other' else isnull(d.race,'other') end),
		x.include_race
	from #config x
		cross join #covid_cohort c
		inner join (
			select patient_num, max(discharge_date) last_discharge_date
			from #admissions
			group by patient_num
		) a on c.patient_num=a.patient_num
		left outer join (
			select patient_num,
				max(sex) sex,
				max(age_group) age_group,
				max(race) race
			from #demographics_temp
			group by patient_num
		) d on c.patient_num=d.patient_num

--------------------------------------------------------------------------------
-- Patient Clinical Course: Status by Number of Days Since Admission
--------------------------------------------------------------------------------

create table #PatientClinicalCourse (
	siteid varchar(50) not null,
	patient_num int not null,
	days_since_admission int not null,
	calendar_date date not null,
	in_hospital int not null,
	severe int not null,
	deceased int not null
)

alter table #PatientClinicalCourse add primary key (patient_num, days_since_admission)

insert into #PatientClinicalCourse (siteid, patient_num, days_since_admission, calendar_date, in_hospital, severe, deceased)
	select distinct '', p.patient_num, 
		datediff(dd,p.admission_date,d.d) days_since_admission,
		d.d calendar_date,
		(case when a.patient_num is not null then 1 else 0 end) in_hospital,
		(case when p.severe=1 and d.d>=p.severe_date then 1 else 0 end) severe,
		(case when p.deceased=1 and d.d>=p.death_date then 1 else 0 end) deceased
	from #PatientSummary p
		inner join #date_list d
			on d.d>=p.admission_date and d.d<=p.last_discharge_date
		left outer join #admissions a
			on a.patient_num=p.patient_num 
				and a.admission_date>=p.admission_date 
				and a.admission_date<=d.d 
				and a.discharge_date>=d.d

--------------------------------------------------------------------------------
-- Patient Observations: Selected Data Facts
--------------------------------------------------------------------------------

create table #PatientObservations (
	siteid varchar(50) not null,
	patient_num int not null,
	days_since_admission int not null,
	concept_type varchar(50) not null,
	concept_code varchar(50) not null,
	value numeric(18,5) not null
)

alter table #PatientObservations add primary key (patient_num, concept_type, concept_code, days_since_admission)

-- Diagnoses (ICD9) before and after COVID
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select '', patient_num, min(days_since_admission), 'DIAG-ICD9', icd_code_3chars, -999
	from (
		select p.patient_num,
			left(substring(f.concept_cd, len(code_prefix_icd9cm)+1, 999), 3) icd_code_3chars,
			(case when f.start_date>=p.admission_date then 1 else 0 end) since_admission,
			datediff(dd,p.admission_date,cast(f.start_date as date)) days_since_admission
 		from #config x
			cross join crc.observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
		where concept_cd like code_prefix_icd9cm+'%' and code_prefix_icd9cm<>''
	) t
	where days_since_admission<=-15 or days_since_admission>=0
	group by patient_num, since_admission, icd_code_3chars

-- Diagnoses (ICD10) before and after COVID
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select '', patient_num, min(days_since_admission), 'DIAG-ICD10', icd_code_3chars, -999
	from (
		select p.patient_num,
			left(substring(f.concept_cd, len(code_prefix_icd10cm)+1, 999), 3) icd_code_3chars,
			(case when f.start_date>=p.admission_date then 1 else 0 end) since_admission,
			datediff(dd,p.admission_date,cast(f.start_date as date)) days_since_admission
 		from #config x
			cross join crc.observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
		where concept_cd like code_prefix_icd10cm+'%' and code_prefix_icd10cm<>''
	) t
	where days_since_admission<=-15 or days_since_admission>=0
	group by patient_num, since_admission, icd_code_3chars

-- Procedures (ICD9) each day since COVID (only procedures used in 4CE Phase 1.1 to determine severity)
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '', p.patient_num,
		datediff(dd,p.admission_date,cast(f.start_date as date)),
		'PROC-ICD9',
		substring(f.concept_cd, len(code_prefix_icd9proc)+1, 999),
		-999
 	from #config x
		cross join crc.observation_fact f
		inner join #covid_cohort p 
			on f.patient_num=p.patient_num 
				and f.start_date >= p.admission_date
	where concept_cd like code_prefix_icd9proc+'%' and code_prefix_icd9proc<>''
		and (
			-- Insertion of endotracheal tube
			f.concept_cd = x.code_prefix_icd9proc+'96.04'
			-- Invasive mechanical ventilation
			or f.concept_cd like x.code_prefix_icd9proc+'96.7[012]'
		)

-- Procedures (ICD10) each day since COVID (only procedures used in 4CE Phase 1.1 to determine severity)
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '', p.patient_num,
		datediff(dd,p.admission_date,cast(f.start_date as date)),
		'PROC-ICD10',
		substring(f.concept_cd, len(code_prefix_icd10pcs)+1, 999),
		-999
 	from #config x
		cross join crc.observation_fact f
		inner join #covid_cohort p 
			on f.patient_num=p.patient_num 
				and f.start_date >= p.admission_date
	where concept_cd like code_prefix_icd10pcs+'%' and code_prefix_icd10pcs<>''
		and (
			-- Insertion of endotracheal tube
			f.concept_cd = x.code_prefix_icd10pcs+'0BH17EZ'
			-- Invasive mechanical ventilation
			or f.concept_cd like x.code_prefix_icd10pcs+'5A09[345]%'
		)

-- Medications (Med Class) before and after COVID
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select '', patient_num, min(days_since_admission), 'MED-CLASS', med_class concept, -999
	from (
		select p.patient_num, m.med_class,	
			(case when f.start_date>=p.admission_date then 1 else 0 end) since_admission,
			datediff(dd,p.admission_date,cast(f.start_date as date)) days_since_admission
		from crc.observation_fact f
			inner join #covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= dateadd(dd,-365,p.admission_date)
			inner join #med_map m
				on f.concept_cd = m.local_med_code
	) t
	where days_since_admission<=-15 or days_since_admission>=0
	group by patient_num, since_admission, med_class

-- Labs (LOINC) each day since COVID
insert into #PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select '', f.patient_num,
		datediff(dd,p.admission_date,f.start_date),
		'LAB-LOINC',		
		l.loinc,
		avg(f.nval_num*l.scale_factor)
	from crc.observation_fact f
		inner join #covid_cohort p 
			on f.patient_num=p.patient_num
		inner join #lab_map l
			on f.concept_cd=l.local_lab_code
	where l.local_lab_code is not null
		and f.nval_num is not null
		and f.nval_num >= 0
		and f.start_date >= p.admission_date
	group by f.patient_num, datediff(dd,p.admission_date,f.start_date), l.loinc


--******************************************************************************
--******************************************************************************
--*** Finalize Tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Replace the patient_num with a random study_num integer
--------------------------------------------------------------------------------

create table #PatientMapping (
	siteid varchar(50) not null,
	patient_num int not null,
	study_num int not null
)

alter table #PatientMapping add primary key (patient_num, study_num)

if exists (select * from #config2 where replace_patient_num = 1)
begin
	insert into #PatientMapping (siteid, patient_num, study_num)
		select '', patient_num, row_number() over (order by newid()) 
		from #PatientSummary
	update t 
		set t.patient_num = m.study_num 
		from #PatientSummary t 
			inner join #PatientMapping m on t.patient_num = m.patient_num
	update t 
		set t.patient_num = m.study_num 
		from #PatientClinicalCourse t 
			inner join #PatientMapping m on t.patient_num = m.patient_num
	update t 
		set t.patient_num = m.study_num 
		from #PatientObservations t 
			inner join #PatientMapping m on t.patient_num = m.patient_num
end
else
begin
	insert into #PatientMapping (siteid, patient_num, study_num)
		select '', patient_num, patient_num
		from #PatientSummary
end

--------------------------------------------------------------------------------
-- Set the siteid to a unique value for your institution.
--------------------------------------------------------------------------------
update #PatientSummary set siteid = (select siteid from #config)
update #PatientClinicalCourse set siteid = (select siteid from #config)
update #PatientObservations set siteid = (select siteid from #config)
update #PatientMapping set siteid = (select siteid from #config)


--******************************************************************************
--******************************************************************************
--*** Finish up
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- OPTION #1: Save the data as tables.
-- * Make sure everything looks reasonable.
-- * Export the tables to csv files.
--------------------------------------------------------------------------------
if exists (select * from #config2 where save_as_columns = 1)
begin
	declare @SaveAsTablesSQL nvarchar(max)
	select @SaveAsTablesSQL = '
		if (select object_id('''+save_as_prefix+'DailyCounts'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'DailyCounts;
		if (select object_id('''+save_as_prefix+'ClinicalCourse'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'ClinicalCourse;
		if (select object_id('''+save_as_prefix+'Demographics'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'Demographics;
		if (select object_id('''+save_as_prefix+'Labs'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'Labs;
		if (select object_id('''+save_as_prefix+'Diagnoses'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'Diagnoses;
		if (select object_id('''+save_as_prefix+'Medications'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'Medications;
		if (select object_id('''+save_as_prefix+'PatientMapping'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'PatientMapping;
		if (select object_id('''+save_as_prefix+'PatientSummary'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'PatientSummary;
		if (select object_id('''+save_as_prefix+'PatientClinicalCourse'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'PatientClinicalCourse;
		if (select object_id('''+save_as_prefix+'PatientObservations'', ''U'') from #config2) is not null
			drop table '+save_as_prefix+'PatientObservations;
		'
		from #config2
	exec sp_executesql @SaveAsTablesSQL
	select @SaveAsTablesSQL = '
		select * into '+save_as_prefix+'DailyCounts from #DailyCounts;
		select * into '+save_as_prefix+'ClinicalCourse from #ClinicalCourse;
		select * into '+save_as_prefix+'Demographics from #Demographics;
		select * into '+save_as_prefix+'Labs from #Labs;
		select * into '+save_as_prefix+'Diagnoses from #Diagnoses;
		select * into '+save_as_prefix+'Medications from #Medications;
		select * into '+save_as_prefix+'PatientMapping from #PatientMapping;
		select * into '+save_as_prefix+'PatientSummary from #PatientSummary;
		select * into '+save_as_prefix+'PatientClinicalCourse from #PatientClinicalCourse;
		select * into '+save_as_prefix+'PatientObservations from #PatientObservations;
		'
		from #config2
	exec sp_executesql @SaveAsTablesSQL
end

--------------------------------------------------------------------------------
-- OPTION #2: View the data as tables.
-- * Make sure everything looks reasonable.
-- * Copy into Excel, convert dates into YYYY-MM-DD format, save in csv format.
--------------------------------------------------------------------------------
if exists (select * from #config2 where output_as_columns = 1)
begin
	select * from #PatientSummary order by admission_date, patient_num
	select * from #PatientClinicalCourse order by patient_num, days_since_admission
	select * from #PatientObservations order by patient_num, concept_type, concept_code, days_since_admission
	select * from #PatientMapping order by patient_num
end

--------------------------------------------------------------------------------
-- OPTION #3: View the data as csv strings.
-- * Copy and paste to a text file, save it FileName.csv.
-- * Make sure it is not saved as FileName.csv.txt.
--------------------------------------------------------------------------------
if exists (select * from #config2 where output_as_csv = 1)
begin

	-- PatientSummary
	select s PatientSummaryCSV
		from (
			select 0 i, 'patient_num,admission_date,days_since_admission,last_discharge_date,still_in_hospital,'
				+'severe_date,severe,death_date,deceased,sex,age_group,race,race_collected' s
			union all 
			select row_number() over (order by admission_date, patient_num) i,
				cast(patient_num as varchar(50))
				+','+convert(varchar(50),admission_date,23) --YYYY-MM-DD
				+','+cast(days_since_admission as varchar(50))
				+','+convert(varchar(50),last_discharge_date,23)
				+','+cast(still_in_hospital as varchar(50))
				+','+convert(varchar(50),severe_date,23)
				+','+cast(severe as varchar(50))
				+','+convert(varchar(50),death_date,23)
				+','+cast(deceased as varchar(50))
				+','+cast(sex as varchar(50))
				+','+cast(age_group as varchar(50))
				+','+cast(race as varchar(50))
				+','+cast(race_collected as varchar(50))
			from #PatientSummary
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- PatientSummary
	select s PatientClinicalCourseCSV
		from (
			select 0 i, 'patient_num,days_since_admission,calendar_date,in_hospital,severe,deceased' s
			union all 
			select row_number() over (order by patient_num, days_since_admission) i,
				cast(patient_num as varchar(50))
				+','+cast(days_since_admission as varchar(50))
				+','+convert(varchar(50),calendar_date,23) --YYYY-MM-DD
				+','+cast(in_hospital as varchar(50))
				+','+cast(severe as varchar(50))
				+','+cast(deceased as varchar(50))
			from #PatientClinicalCourse
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i


	-- PatientObservations
	select s PatientObservationsCSV
		from (
			select 0 i, 'patient_num,days_since_admission,concept_type,concept_code,value' s
			union all 
			select row_number() over (order by patient_num, concept_type, concept_code, days_since_admission) i,
				cast(patient_num as varchar(50))
				+','+cast(days_since_admission as varchar(50))
				+','+cast(concept_type as varchar(50))
				+','+cast(concept_code as varchar(50))
				+','+cast(value as varchar(50))
			from #PatientObservations
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

	-- PatientMapping
	select s PatientMappingCSV
		from (
			select 0 i, 'patient_num,study_num' s
			union all 
			select row_number() over (order by patient_num) i,
				cast(patient_num as varchar(50))
				+','+cast(study_num as varchar(50))
			from #PatientMapping
			union all select 9999999, '' --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i

end

