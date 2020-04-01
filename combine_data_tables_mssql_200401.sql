
--****************************************************************************
--****************************************************************************
--*** Load marged CSV files into temp tables and cleanup
--****************************************************************************
--****************************************************************************

------------------------------------------------------------------------------
-- Load merged data
------------------------------------------------------------------------------
select * into #daily_raw from merge_200401_daily
select * into #demographics_raw from merge_200401_demographics
select * into #labs_raw from merge_200401_labs
select * into #diagnoses_raw from merge_200401_diagnoses

------------------------------------------------------------------------------
-- Remove quotes and blank spaces
------------------------------------------------------------------------------
update #daily_raw set 
	siteid=ltrim(rtrim(replace(siteid,'"',''))),
	date=ltrim(rtrim(replace(date,'"',''))),
	new_positive_cases=ltrim(rtrim(replace(new_positive_cases,'"',''))),
	patients_in_icu=ltrim(rtrim(replace(patients_in_icu,'"',''))),
	new_deaths=ltrim(rtrim(replace(new_deaths,'"','')))

update #demographics_raw set 
	siteid=ltrim(rtrim(replace(siteid,'"',''))),
	sex=ltrim(rtrim(replace(sex,'"',''))),
	total_patients=ltrim(rtrim(replace(total_patients,'"',''))),
	age_0to2=ltrim(rtrim(replace(age_0to2,'"',''))),
	age_3to5=ltrim(rtrim(replace(age_3to5,'"',''))),
	age_6to11=ltrim(rtrim(replace(age_6to11,'"',''))),
	age_12to17=ltrim(rtrim(replace(age_12to17,'"',''))),
	age_18to25=ltrim(rtrim(replace(age_18to25,'"',''))),
	age_26to49=ltrim(rtrim(replace(age_26to49,'"',''))),
	age_50to69=ltrim(rtrim(replace(age_50to69,'"',''))),
	age_70to79=ltrim(rtrim(replace(age_70to79,'"',''))),
	age_80plus=ltrim(rtrim(replace(age_80plus,'"','')))

update #labs_raw set 
	siteid=ltrim(rtrim(replace(siteid,'"',''))),
	loinc=ltrim(rtrim(replace(loinc,'"',''))),
	days_since_positive=ltrim(rtrim(replace(days_since_positive,'"',''))),
	num_patients=ltrim(rtrim(replace(num_patients,'"',''))),
	mean_value=ltrim(rtrim(replace(mean_value,'"',''))),
	stdev_val=ltrim(rtrim(replace(stdev_val,'"','')))

update #diagnoses_raw set 
	siteid=ltrim(rtrim(replace(siteid,'"',''))),
	icd_code=ltrim(rtrim(replace(icd_code,'"',''))),
	icd_version=ltrim(rtrim(replace(icd_version,'"',''))),
	num_patients=ltrim(rtrim(replace(num_patients,'"','')))

------------------------------------------------------------------------------
-- Handle special cases
------------------------------------------------------------------------------
update #labs_raw set stdev_val=NULL where stdev_val in ('NULL','NA','')
update #labs_raw set stdev_val=NULL where num_patients='1'
update #labs_raw set loinc=left(loinc,charindex(' ',loinc)-1) where loinc like '% %'

------------------------------------------------------------------------------
-- Delete header rows
------------------------------------------------------------------------------
delete from #daily_raw where siteid='siteid'
delete from #demographics_raw where siteid='siteid'
delete from #labs_raw where siteid='siteid'
delete from #diagnoses_raw where siteid='siteid'


--****************************************************************************
--****************************************************************************
--*** Saved the cleaned up data to new temp tables
--****************************************************************************
--****************************************************************************

select siteid, 
		cast(date as date) date, 
		cast(new_positive_cases as int) new_positive_cases,
		cast(patients_in_icu as int) patients_in_icu,
		cast(new_deaths as int) new_deaths
	into #daily
	from #daily_raw


select siteid,
		sex,
		cast(total_patients as int) total_patients,
		cast(age_0to2 as int) age_0to2,
		cast(age_3to5 as int) age_3to5,
		cast(age_6to11 as int) age_6to11,
		cast(age_12to17 as int) age_12to17,
		cast(age_18to25 as int) age_18to25,
		cast(age_26to49 as int) age_26to49,
		cast(age_50to69 as int) age_50to69,
		cast(age_70to79 as int) age_70to79,
		cast(age_80plus as int) age_80plus
	into #demographics
	from #demographics_raw


select siteid,
		loinc,
		cast(days_since_positive as int) days_since_positive,
		cast(num_patients as int) num_patients,
		cast(mean_value as float) mean_value,
		cast(stdev_val as float) stdev_val
	into #labs
	from #labs_raw


select siteid,
		icd_code,
		cast(icd_version as int) icd_version,
		cast(num_patients as int) num_patients
	into #diagnoses
	from #diagnoses_raw


--****************************************************************************
--****************************************************************************
--*** Create the output CSV files
--****************************************************************************
--****************************************************************************


------------------------------------------------------------------------------
-- This table stores the obfuscation parameters of each site
------------------------------------------------------------------------------
--create table obfuscation (
--	siteid varchar(100) primary key,
--	threshold int,
--	blur int
--)


select 'Combined' siteid, date,
		isnull(sum(case when new_positive_cases>=0 then new_positive_cases else null end),0) new_positive_cases,
		isnull(sum(case when patients_in_icu>=0 then patients_in_icu else null end),0) patients_in_icu,
		isnull(sum(case when new_deaths>=0 then new_deaths else null end),0) new_deaths,
		sum(case when new_positive_cases>=0 then 1 else 0 end) unmasked_sites_new_positive_cases,
		sum(case when patients_in_icu>=0 then 1 else 0 end) unmasked_sites_patients_in_icu,
		sum(case when new_deaths>=0 then 1 else 0 end) unmasked_sites_new_deaths,
		sum(case when new_positive_cases=-1 then 1 else 0 end) masked_sites_new_positive_cases,
		sum(case when patients_in_icu=-1 then 1 else 0 end) masked_sites_patients_in_icu,
		sum(case when new_deaths=-1 then 1 else 0 end) masked_sites_new_deaths,
		sum(case when new_positive_cases=-1 then t.threshold-1 else 0 end) masked_upper_bound_new_positive_cases,
		sum(case when patients_in_icu=-1 then t.threshold-1 else 0 end) masked_upper_bound_patients_in_icu,
		sum(case when new_deaths=-1 then t.threshold-1 else 0 end) masked_upper_bound_new_deaths
	from #daily c left outer join obfuscation t on c.siteid=t.siteid
	group by date
	order by date


select 'Combined' siteid, sex,
		isnull(sum(case when total_patients>=0 then total_patients else null end),0) total_patients,
		isnull(sum(case when age_0to2>=0 then age_0to2 else null end),0) age_0to2,
		isnull(sum(case when age_3to5>=0 then age_3to5 else null end),0) age_3to5,
		isnull(sum(case when age_6to11>=0 then age_6to11 else null end),0) age_6to11,
		isnull(sum(case when age_12to17>=0 then age_12to17 else null end),0) age_12to17,
		isnull(sum(case when age_18to25>=0 then age_18to25 else null end),0) age_18to25,
		isnull(sum(case when age_26to49>=0 then age_26to49 else null end),0) age_26to49,
		isnull(sum(case when age_50to69>=0 then age_50to69 else null end),0) age_50to69,
		isnull(sum(case when age_70to79>=0 then age_70to79 else null end),0) age_70to79,
		isnull(sum(case when age_80plus>=0 then age_80plus else null end),0) age_80plus,
		sum(case when total_patients>=0 then 1 else 0 end) unmasked_sites_total_patients,
		sum(case when age_0to2>=0 then 1 else 0 end) unmasked_sites_age_0to2,
		sum(case when age_3to5>=0 then 1 else 0 end) unmasked_sites_age_3to5,
		sum(case when age_6to11>=0 then 1 else 0 end) unmasked_sites_age_6to11,
		sum(case when age_12to17>=0 then 1 else 0 end) unmasked_sites_age_12to17,
		sum(case when age_18to25>=0 then 1 else 0 end) unmasked_sites_age_18to25,
		sum(case when age_26to49>=0 then 1 else 0 end) unmasked_sites_age_26to49,
		sum(case when age_50to69>=0 then 1 else 0 end) unmasked_sites_age_50to69,
		sum(case when age_70to79>=0 then 1 else 0 end) unmasked_sites_age_70to79,
		sum(case when age_80plus>=0 then 1 else 0 end) unmasked_sites_age_80plus,
		sum(case when total_patients=-1 then 1 else 0 end) masked_sites_total_patients,
		sum(case when age_0to2=-1 then 1 else 0 end) masked_sites_age_0to2,
		sum(case when age_3to5=-1 then 1 else 0 end) masked_sites_age_3to5,
		sum(case when age_6to11=-1 then 1 else 0 end) masked_sites_age_6to11,
		sum(case when age_12to17=-1 then 1 else 0 end) masked_sites_age_12to17,
		sum(case when age_18to25=-1 then 1 else 0 end) masked_sites_age_18to25,
		sum(case when age_26to49=-1 then 1 else 0 end) masked_sites_age_26to49,
		sum(case when age_50to69=-1 then 1 else 0 end) masked_sites_age_50to69,
		sum(case when age_70to79=-1 then 1 else 0 end) masked_sites_age_70to79,
		sum(case when age_80plus=-1 then 1 else 0 end) masked_sites_age_80plus,
		sum(case when total_patients=-1 then t.threshold-1 else 0 end) masked_upper_bound_total_patients,
		sum(case when age_0to2=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_0to2,
		sum(case when age_3to5=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_3to5,
		sum(case when age_6to11=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_6to11,
		sum(case when age_12to17=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_12to17,
		sum(case when age_18to25=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_18to25,
		sum(case when age_26to49=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_26to49,
		sum(case when age_50to69=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_50to69,
		sum(case when age_70to79=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_70to79,
		sum(case when age_80plus=-1 then t.threshold-1 else 0 end) masked_upper_bound_age_80plus
	from #demographics c left outer join obfuscation t on c.siteid=t.siteid
	group by sex
	order by sex


select 'Combined' siteid, loinc, days_since_positive,
		isnull(sum(case when num_patients>=0 then num_patients else null end),0) num_patients,
		(case when sum(case when num_patients>=0 then 1 else 0 end)=0
				then -1
			else sum(case when num_patients>=0 then num_patients*mean_value else 0 end)
				/cast(sum(case when num_patients>=0 then num_patients else 0 end) as float)
			end) mean_value,
		(case when sum(case when num_patients>=0 then 1 else 0 end)=0
				then -1
			else isnull(sum(case when num_patients>=0 then num_patients*stdev_val else 0 end)
				/cast(sum(case when num_patients>=0 then num_patients else 0 end) as float),-2)
			end) stdev_val,
		sum(case when num_patients>=0 then 1 else 0 end) unmasked_sites_num_patients,
		sum(case when num_patients=-1 then 1 else 0 end) masked_sites_num_patients,
		sum(case when num_patients=-1 then t.threshold-1 else 0 end) masked_upper_bound_num_patients
	from #labs c left outer join obfuscation t on c.siteid=t.siteid
	group by loinc, days_since_positive
	order by loinc, days_since_positive


select 'Combined' siteid, icd_code, icd_version, 
		isnull(sum(case when num_patients>=0 then num_patients else null end),0) num_patients,
		sum(case when num_patients>=0 then 1 else 0 end) unmasked_sites_num_patients,
		sum(case when num_patients=-1 then 1 else 0 end) masked_sites_num_patients,
		sum(case when num_patients=-1 then t.threshold-1 else 0 end) masked_upper_bound_num_patients
	from #diagnoses c left outer join obfuscation t on c.siteid=t.siteid
	group by icd_code, icd_version
	order by num_patients desc, icd_version, icd_code



