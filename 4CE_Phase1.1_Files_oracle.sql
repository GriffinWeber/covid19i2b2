
--Cleanup scripts if necessary
/*
  drop table covid_config;
  drop table covid_code_map;
  drop table covid_lab_map;
  drop table covid_med_map;
  drop table covid_date_list_temp;
  drop table covid_demographics_temp;
  drop table covid_admissions;
  drop table covid_pos_patients;
  drop table covid_cohort;
  drop table covid_severe_patients;
  drop table covid_demographics;
  drop table covid_daily_counts;
  drop table covid_clinical_course;
  drop table covid_labs;
  drop table covid_medications;
  drop table covid_diagnoses;
*/
--------------------------------------------------------------------------------
-- General settings
--------------------------------------------------------------------------------
create table covid_config (
	siteid varchar(20), -- Up to 20 letters or numbers, must start with letter, no spaces or special characters.
	include_race number(1), -- 1 if your site collects race/ethnicity data; 0 if your site does not collect this.
	race_in_fact_table number(1), -- 1 if race in observation_fact.concept_cd; 0 if in patient_dimension.race_cd
	hispanic_in_fact_table number(1), -- 1 if Hispanic/Latino in observation_fact.concept_cd; 0 if in patient_dimension.race_cd
	death_data_accurate number(1), -- 1 if the patient_dimension.death_date field is populated and is accurate
	code_prefix_icd9cm varchar(50), -- prefix (scheme) used in front of a ICD9CM diagnosis code [required]
	code_prefix_icd10cm varchar(50), -- prefix (scheme) used in front of a ICD10CM diagnosis code [required]
	code_prefix_icd9proc varchar(50), -- prefix (scheme) used in front of a ICD9 procedure code [required]
	code_prefix_icd10pcs varchar(50), -- prefix (scheme) used in front of a ICD10 procedure code [required]
	obfuscation_blur number(8,0), -- Add random number +/-blur to each count (0 = no blur)
	obfuscation_small_count_mask number(8,0), -- Replace counts less than mask with -99 (0 = no small count masking)
	obfuscation_small_count_delete number(1), -- Delete rows with small counts (0 = no, 1 = yes)
	obfuscation_demographics number(1), -- Replace combination demographics and total counts with -999 (0 = no, 1 = yes)
	output_as_columns number(1), -- Return the data in tables with separate columns per field
	output_as_csv number(1) -- Return the data in tables with a single column containing comma separated values
);
insert into COVID_CONFIG
	select 'YOUR_ID', -- siteid
		1, -- include_race
		0, -- race_in_fact_table
		0, -- hispanic_in_fact_table
		1, -- death_data_accurate
		'DIAG|ICD9:', -- code_prefix_icd9cm
		'DIAG|ICD10:', -- code_prefix_icd10cm
		'PROC|ICD9:', -- code_prefix_icd9proc
		'PROC|ICD10:', -- code_prefix_icd10pcs
		0, -- obfuscation_blur
		10, -- obfuscation_small_count_mask
		0, -- obfuscation_small_count_delete
		0, -- obfuscation_demographics
		0, -- output_as_columns
		1 -- output_as_csv
    from dual;    
commit;
-- ! If your ICD codes do not start with a prefix (e.g., "ICD:"), then you will
-- ! need to customize the query that populates the covid_diagnoses table so that
-- ! only diagnosis codes are selected from the observation_fact table.

--------------------------------------------------------------------------------
-- Code mappings (excluding labs and meds)
-- * Don't change the "code" value.
-- * Modify the "local_code" to match your database.
-- * Repeat a code multiple times if you have more than one local code.
--------------------------------------------------------------------------------
create table COVID_CODE_MAP (
	code varchar(50) not null,
	local_code varchar(50) not null,
    constraint COVID_CODEMAP_PK PRIMARY KEY (code, local_code)
);

-- Inpatient visits (visit_dimension.inout_cd)
insert into  COVID_CODE_MAP
	select 'inpatient', 'I' from dual
        union all 
    select 'inpatient', 'IN' from dual;
    --UNC: 'INPATIENT'
commit;    
-- Sex (patient_dimension.sex_cd)
insert into  COVID_CODE_MAP
	select 'male', 'M' from dual
        union all 
    select 'male', 'Male' from dual
        union all 
    select 'female', 'F' from dual
        union all 
    select 'female', 'Female' from dual;
commit;    
-- Race (field based on covid_config.race_in_fact_table; ignore if you don't collect race/ethnicity)
insert into  COVID_CODE_MAP
	select 'american_indian', 'NA' from dual
        union all 
    select 'asian', 'A' from dual
        union all 
    select 'asian', 'AS' from dual
        union all 
    select 'black', 'B' from dual
        union all 
    select 'hawaiian_pacific_islander', 'H' from dual
        union all 
    select 'hawaiian_pacific_islander', 'P' from dual
        union all 
    select 'white', 'W' from dual;
commit; 
--UNC: white:'1', islander:'5', black:'2',asian:'4',native:'3'

-- Hispanic/Latino (field based on covid_config.hispanic_in_fact_table; ignore if you don't collect race/ethnicity)
insert into  COVID_CODE_MAP
	select 'hispanic_latino', 'DEM|HISP:Y' from dual
        union all 
    select 'hispanic_latino', 'DEM|HISPANIC:Y' from dual;
commit; 
--UNC: HISP:'2',No:'1'

-- Codes that indicate a positive COVID-19 test result (use either option #1 and/or option #2)
-- COVID-19 Positive Option #1: individual concept_cd values
insert into  COVID_CODE_MAP
	select 'covidpos', 'LOINC:COVID19POS' from dual;
commit;

-- COVID-19 Positive Option #2: an ontology path (the example here is the COVID ACT "Any Positive Test" path)
insert into  COVID_CODE_MAP
	select distinct 'covidpos', concept_cd
	from concept_dimension c
	where concept_path like '\ACT\UMLS_C0031437\SNOMED_3947185011\UMLS_C0022885\UMLS_C1335447\%'
		and concept_cd is not null
		and not exists (select * from COVID_CODE_MAP m where m.code='covidpos' and m.local_code=c.concept_cd);
commit;        

--------------------------------------------------------------------------------
-- Lab mappings
-- * Do not change the loinc column or the lab_units column.
-- * Modify the local_code column for the code you use.
-- * Add another row for a lab if you use multiple codes (e.g., see PaO2).
-- * Delete a row if you don't have that lab.
-- * Change the scale_factor if you use different units.
-- * The lab value will be multiplied by the scale_factor
-- *   to convert from your units to the 4CE units.
--------------------------------------------------------------------------------
create table COVID_LAB_MAP (
	loinc varchar(20) not null, 
	local_lab_code varchar(50) not null, 
	scale_factor numeric(4), 
	lab_units varchar(20), 
	lab_name varchar(100),
    constraint COVID_LABMAP_PK PRIMARY KEY (loinc, local_lab_code)
);

insert into COVID_LAB_MAP
	select loinc, 'LOINC:'||local_lab_code,  -- Change "LOINC:" to your local LOINC code prefix (scheme)
		scale_factor, lab_units, lab_name
	from (
		select '6690-2' loinc, '6690-2' local_lab_code, 1 scale_factor, '10*3/uL' lab_units, 'white blood cell count (Leukocytes)' lab_name from dual   
            union 
        select '6690-2', '12227-5', 1, '10*3/uL', 'white blood cell count (Leukocytes)' from dual
            union     
        select '751-8','751-8',1,'10*3/uL','neutrophil count' from dual
            union 
        select '731-0','731-0',1,'10*3/uL','lymphocyte count' from dual
            union 
        select '1751-7','1752-5',1,'g/dL','albumin' from dual
            union 
        select '2532-0','2532-0',1,'U/L','lactate dehydrogenase (LDH)' from dual
            union 
        select '1742-6','1742-6',1,'U/L','alanine aminotransferase (ALT)' from dual
            union 
        select '1920-8','1920-8',1,'U/L','aspartate aminotransferase (AST)' from dual
            union 
        select '1975-2','1975-2',1,'mg/dL','total bilirubin' from dual
            union 
        select '2160-0','2160-0',1,'mg/dL','creatinine' from dual
            union 
        select '49563-0','49563-0',1,'ng/mL','cardiac troponin (High Sensitivity)' from dual
            union 
        select '6598-7','6598-7',1,'ug/L','cardiac troponin (Normal Sensitivity)' from dual
            union 
        select '6598-7','10839-9',1,'ug/L','cardiac troponin (Normal Sensitivity)' from dual
            union    
        select '48065-7','48065-7',1,'ng/mL{FEU}','D-dimer (FEU)' from dual
            union 
        select '48066-5','48066-5',1,'ng/mL{DDU}','D-dimer (DDU)' from dual
            union 
        select '5902-2','5902-2',1,'s','prothrombin time (PT)' from dual
            union 
        select '33959-8','33959-8',1,'ng/mL','procalcitonin' from dual
            union 
        select '1988-5','1988-5',1,'mg/L','C-reactive protein (CRP) (Normal Sensitivity)' from dual
            union 
        select '3255-7','3255-7',1,'mg/dL','Fibrinogen' from dual
            union 
        select '2276-4','2276-4',1,'ng/mL','Ferritin' from dual
            union 
        select '2019-8','2019-8',1,'mmHg','PaCO2' from dual
            union 
        select '2019-8','2021-4',1,'mmHg','PaCO2' from dual
            union    
        select '2019-8','2020-6',1,'mmHg','PaCO2' from dual
            union
        select '2703-7','2703-7',1,'mmHg','PaO2' from dual
            union
        select '2703-7','2705-2',1,'mmHg','PaO2' from dual
            union
        select '2703-7','2704-5',1,'mmHg','PaO2' from dual
		--union select '2703-7','second-code',1,'mmHg','PaO2'
		--union select '2703-7','third-code',1,'mmHg','PaO2'
	) t;
commit;

-- Use the concept_dimension to get an expanded list of local lab codes (optional).
-- Uncomment the query below to run this as part of the script.
-- This will pull in additional labs based on your existing mappings.
-- It will find paths corresponding to concepts already in the covid_lab_map table,
--   and then find all the concepts corresponding to child paths.
-- NOTE: Make sure to adjust the scale_factor if any of these additional
--   lab codes use different units than their parent code.
-- WARNING: This query might take several minutes to run.
/*
insert into COVID_LAB_MAP
	select distinct l.loinc, d.concept_cd, l.scale_factor, l.lab_units, l.lab_name
	from COVID_LAB_MAP l
		inner join concept_dimension c
			on l.local_lab_code = c.concept_cd
		inner join concept_dimension d
			on d.concept_path like c.concept_path+'%'
	where not exists (
		select *
		from COVID_LAB_MAP t
		where t.loinc = l.loinc and t.local_lab_code = d.concept_cd
	);
commit;    
*/

--------------------------------------------------------------------------------
-- Medication mappings
-- * Do not change the med_class or add additional medications.
-- * The ATC and RxNorm codes represent the same list of medications.
-- * Use ATC and/or RxNorm, depending on what your institution uses.
--------------------------------------------------------------------------------
create table COVID_MED_MAP (
	med_class varchar(50) not null,
	code_type varchar(10) not null,
	local_med_code varchar(50) not null,
    constraint COVID_MEDMAP_PK primary key (med_class, code_type, local_med_code)
);

-- ATC codes (optional)
insert into COVID_MED_MAP
	select m, 'ATC' t, 'ATC:'||c  -- Change "ATC:" to your local ATC code prefix (scheme)
	from (
		-- Don't add or remove drugs
		select 'ACEI' m, c from (select 'C09AA01' c from dual union select 'C09AA02' from dual union select 'C09AA03' from dual union select 'C09AA04' from dual union select 'C09AA05' from dual union select 'C09AA06' from dual union select 'C09AA07' from dual union select 'C09AA08' from dual union select 'C09AA09' from dual union select 'C09AA10' from dual union select 'C09AA11' from dual union select 'C09AA13' from dual union select 'C09AA15' from dual union select 'C09AA16' from dual) t
		union select 'ARB', c from (select 'C09CA01' c from dual union select 'C09CA02' from dual union select 'C09CA03' from dual union select 'C09CA04' from dual union select 'C09CA06' from dual union select 'C09CA07' from dual union select 'C09CA08' from dual) t
		union select 'COAGA', c from (select 'B01AC04' c from dual union select 'B01AC05' from dual union select 'B01AC07' from dual union select 'B01AC10' from dual union select 'B01AC13' from dual union select 'B01AC16' from dual union select 'B01AC17' from dual union select 'B01AC22' from dual union select 'B01AC24' from dual union select 'B01AC25' from dual union select 'B01AC26' from dual) t
		union select 'COAGB', c from (select 'B01AA01' c from dual union select 'B01AA03' from dual union select 'B01AA04' from dual union select 'B01AA07' from dual union select 'B01AA11' from dual union select 'B01AB01' from dual union select 'B01AB04' from dual union select 'B01AB05' from dual union select 'B01AB06' from dual union select 'B01AB07' from dual union select 'B01AB08' from dual union select 'B01AB10' from dual union select 'B01AB12' from dual union select 'B01AE01' from dual union select 'B01AE02' from dual union select 'B01AE03' from dual union select 'B01AE06' from dual union select 'B01AE07' from dual union select 'B01AF01' from dual union select 'B01AF02' from dual union select 'B01AF03' from dual union select 'B01AF04' from dual union select 'B01AX05' from dual union select 'B01AX07' from dual) t
		union select 'COVIDVIRAL', c from (select 'J05AE10' c from dual union select 'J05AP01' from dual union select 'J05AR10' from dual) t
		union select 'DIURETIC', c from (select 'C03CA01' c from dual union select 'C03CA02' from dual union select 'C03CA03' from dual union select 'C03CA04' from dual union select 'C03CB01' from dual union select 'C03CB02' from dual union select 'C03CC01' from dual) t
		union select 'HCQ', c from (select 'P01BA01' c from dual union select 'P01BA02' from dual) t
		union select 'ILI', c from (select 'L04AC03' c from dual union select 'L04AC07' from dual union select 'L04AC11' from dual union select 'L04AC14' from dual) t
		union select 'INTERFERON', c from (select 'L03AB08' c from dual union select 'L03AB11' from dual) t
		union select 'SIANES', c from (select 'M03AC03' c from dual union select 'M03AC09' from dual union select 'M03AC11' from dual union select 'N01AX03' from dual union select 'N01AX10' from dual union select 'N05CD08' from dual union select 'N05CM18' from dual) t
		union select 'SICARDIAC', c from (select 'B01AC09' c from dual union select 'C01CA03' from dual union select 'C01CA04' from dual union select 'C01CA06' from dual union select 'C01CA07' from dual union select 'C01CA24' from dual union select 'C01CE02' from dual union select 'C01CX09' from dual union select 'H01BA01' from dual union select 'R07AX01' from dual) t
	) t;
commit;    

-- RxNorm codes (optional)
insert into COVID_MED_MAP
	select m, 'RxNorm' t, 'RxNorm:'||c  -- Change "RxNorm:" to your local RxNorm code prefix (scheme)
	from (
		-- Don't add or remove drugs
		select 'ACEI' m, c from (select '36908' c from dual union select '39990' from dual union select '104375' from dual union select '104376' from dual union select '104377' from dual union select '104378' from dual union select '104383' from dual union select '104384' from dual union select '104385' from dual union select '1299896' from dual union select '1299897' from dual union select '1299963' from dual union select '1299965' from dual union select '1435623' from dual union select '1435624' from dual union select '1435630' from dual union select '1806883' from dual union select '1806884' from dual union select '1806890' from dual union select '18867' from dual union select '197884' from dual union select '198187' from dual union select '198188' from dual union select '198189' from dual union select '199351' from dual union select '199352' from dual union select '199353' from dual union select '199622' from dual union select '199707' from dual union select '199708' from dual union select '199709' from dual union select '1998' from dual union select '199816' from dual union select '199817' from dual union select '199931' from dual union select '199937' from dual union select '205326' from dual union select '205707' from dual union select '205778' from dual union select '205779' from dual union select '205780' from dual union select '205781' from dual union select '206277' from dual union select '206313' from dual union select '206764' from dual union select '206765' from dual union select '206766' from dual union select '206771' from dual union select '207780' from dual union select '207792' from dual union select '207800' from dual union select '207820' from dual union select '207891' from dual union select '207892' from dual union select '207893' from dual union select '207895' from dual union select '210671' from dual union select '210672' from dual union select '210673' from dual union select '21102' from dual union select '211535' from dual union select '213482' from dual union select '247516' from dual union select '251856' from dual union select '251857' from dual union select '260333' from dual union select '261257' from dual union select '261258' from dual union select '261962' from dual union select '262076' from dual union select '29046' from dual union select '30131' from dual union select '308607' from dual union select '308609' from dual union select '308612' from dual union select '308613' from dual union select '308962' from dual union select '308963' from dual union select '308964' from dual union select '310063' from dual union select '310065' from dual union select '310066' from dual union select '310067' from dual union select '310422' from dual union select '311353' from dual union select '311354' from dual union select '311734' from dual union select '311735' from dual union select '312311' from dual union select '312312' from dual union select '312313' from dual union select '312748' from dual union select '312749' from dual union select '312750' from dual union select '313982' from dual union select '313987' from dual union select '314076' from dual union select '314077' from dual union select '314203' from dual union select '317173' from dual union select '346568' from dual union select '347739' from dual union select '347972' from dual union select '348000' from dual union select '35208' from dual union select '35296' from dual union select '371001' from dual union select '371254' from dual union select '371506' from dual union select '372007' from dual union select '372274' from dual union select '372614' from dual union select '372945' from dual union select '373293' from dual union select '373731' from dual union select '373748' from dual union select '373749' from dual union select '374176' from dual union select '374177' from dual union select '374938' from dual union select '378288' from dual union select '3827' from dual union select '38454' from dual union select '389182' from dual union select '389183' from dual union select '389184' from dual union select '393442' from dual union select '401965' from dual union select '401968' from dual union select '411434' from dual union select '50166' from dual union select '542702' from dual union select '542704' from dual union select '54552' from dual union select '60245' from dual union select '629055' from dual union select '656757' from dual union select '807349' from dual union select '845488' from dual union select '845489' from dual union select '854925' from dual union select '854927' from dual union select '854984' from dual union select '854986' from dual union select '854988' from dual union select '854990' from dual union select '857169' from dual union select '857171' from dual union select '857183' from dual union select '857187' from dual union select '857189' from dual union select '858804' from dual union select '858806' from dual union select '858810' from dual union select '858812' from dual union select '858813' from dual union select '858815' from dual union select '858817' from dual union select '858819' from dual union select '858821' from dual union select '898687' from dual union select '898689' from dual union select '898690' from dual union select '898692' from dual union select '898719' from dual union select '898721' from dual union select '898723' from dual union select '898725' from dual ) t
		union select 'ARB', c from (select '118463' c from dual union select '108725' from dual union select '153077' from dual union select '153665' from dual union select '153666' from dual union select '153667' from dual union select '153821' from dual union select '153822' from dual union select '153823' from dual union select '153824' from dual union select '1996253' from dual union select '1996254' from dual union select '199850' from dual union select '199919' from dual union select '200094' from dual union select '200095' from dual union select '200096' from dual union select '205279' from dual union select '205304' from dual union select '205305' from dual union select '2057151' from dual union select '2057152' from dual union select '2057158' from dual union select '206256' from dual union select '213431' from dual union select '213432' from dual union select '214354' from dual union select '261209' from dual union select '261301' from dual union select '282755' from dual union select '284531' from dual union select '310139' from dual union select '310140' from dual union select '311379' from dual union select '311380' from dual union select '314073' from dual union select '349199' from dual union select '349200' from dual union select '349201' from dual union select '349483' from dual union select '351761' from dual union select '351762' from dual union select '352001' from dual union select '352274' from dual union select '370704' from dual union select '371247' from dual union select '372651' from dual union select '374024' from dual union select '374279' from dual union select '374612' from dual union select '378276' from dual union select '389185' from dual union select '484824' from dual union select '484828' from dual union select '484855' from dual union select '52175' from dual union select '577776' from dual union select '577785' from dual union select '577787' from dual union select '598024' from dual union select '615856' from dual union select '639536' from dual union select '639537' from dual union select '639539' from dual union select '639543' from dual union select '69749' from dual union select '73494' from dual union select '83515' from dual union select '83818' from dual union select '979480' from dual union select '979482' from dual union select '979485' from dual union select '979487' from dual union select '979492' from dual union select '979494' from dual ) t
		union select 'COAGA', c from (select '27518' c from dual union select '10594' from dual union select '108911' from dual union select '1116632' from dual union select '1116634' from dual union select '1116635' from dual union select '1116639' from dual union select '1537034' from dual union select '1537038' from dual union select '1537039' from dual union select '1537045' from dual union select '1656052' from dual union select '1656055' from dual union select '1656056' from dual union select '1656061' from dual union select '1656683' from dual union select '1666332' from dual union select '1666334' from dual union select '1736469' from dual union select '1736470' from dual union select '1736472' from dual union select '1736477' from dual union select '1736478' from dual union select '1737465' from dual union select '1737466' from dual union select '1737468' from dual union select '1737471' from dual union select '1737472' from dual union select '1812189' from dual union select '1813035' from dual union select '1813037' from dual union select '197622' from dual union select '199314' from dual union select '200348' from dual union select '200349' from dual union select '205253' from dual union select '206714' from dual union select '207569' from dual union select '208316' from dual union select '208558' from dual union select '213169' from dual union select '213299' from dual union select '241162' from dual union select '261096' from dual union select '261097' from dual union select '309362' from dual union select '309952' from dual union select '309953' from dual union select '309955' from dual union select '313406' from dual union select '32968' from dual union select '333833' from dual union select '3521' from dual union select '371917' from dual union select '374131' from dual union select '374583' from dual union select '375035' from dual union select '392451' from dual union select '393522' from dual union select '613391' from dual union select '73137' from dual union select '749196' from dual union select '749198' from dual union select '75635' from dual union select '83929' from dual union select '855811' from dual union select '855812' from dual union select '855816' from dual union select '855818' from dual union select '855820' from dual ) t
		union select 'COAGB', c from (select '2110605' c from dual union select '237057' from dual union select '69528' from dual union select '8150' from dual union select '163426' from dual union select '1037042' from dual union select '1037044' from dual union select '1037045' from dual union select '1037049' from dual union select '1037179' from dual union select '1037181' from dual union select '1110708' from dual union select '1114195' from dual union select '1114197' from dual union select '1114198' from dual union select '1114202' from dual union select '11289' from dual union select '114934' from dual union select '1232082' from dual union select '1232084' from dual union select '1232086' from dual union select '1232088' from dual union select '1241815' from dual union select '1241823' from dual union select '1245458' from dual union select '1245688' from dual union select '1313142' from dual union select '1359733' from dual union select '1359900' from dual union select '1359967' from dual union select '1360012' from dual union select '1360432' from dual union select '1361029' from dual union select '1361038' from dual union select '1361048' from dual union select '1361226' from dual union select '1361568' from dual union select '1361574' from dual union select '1361577' from dual union select '1361607' from dual union select '1361613' from dual union select '1361615' from dual union select '1361853' from dual union select '1362024' from dual union select '1362026' from dual union select '1362027' from dual union select '1362029' from dual union select '1362030' from dual union select '1362048' from dual union select '1362052' from dual union select '1362054' from dual union select '1362055' from dual union select '1362057' from dual union select '1362059' from dual union select '1362060' from dual union select '1362061' from dual union select '1362062' from dual union select '1362063' from dual union select '1362065' from dual union select '1362067' from dual union select '1362824' from dual union select '1362831' from dual union select '1362837' from dual union select '1362935' from dual union select '1362962' from dual union select '1364430' from dual union select '1364434' from dual union select '1364435' from dual union select '1364441' from dual union select '1364445' from dual union select '1364447' from dual union select '1490491' from dual union select '1490493' from dual union select '15202' from dual union select '152604' from dual union select '154' from dual union select '1549682' from dual union select '1549683' from dual union select '1598' from dual union select '1599538' from dual union select '1599542' from dual union select '1599543' from dual union select '1599549' from dual union select '1599551' from dual union select '1599553' from dual union select '1599555' from dual union select '1599557' from dual union select '1656595' from dual union select '1656599' from dual union select '1656760' from dual union select '1657991' from dual union select '1658634' from dual union select '1658637' from dual union select '1658647' from dual union select '1658659' from dual union select '1658690' from dual union select '1658692' from dual union select '1658707' from dual union select '1658717' from dual union select '1658719' from dual union select '1658720' from dual union select '1659195' from dual union select '1659197' from dual union select '1659260' from dual union select '1659263' from dual union select '1723476' from dual union select '1723478' from dual union select '1798389' from dual union select '1804730' from dual union select '1804735' from dual union select '1804737' from dual union select '1804738' from dual union select '1807809' from dual union select '1856275' from dual union select '1856278' from dual union select '1857598' from dual union select '1857949' from dual union select '1927851' from dual union select '1927855' from dual union select '1927856' from dual union select '1927862' from dual union select '1927864' from dual union select '1927866' from dual union select '197597' from dual union select '198349' from dual union select '1992427' from dual union select '1992428' from dual union select '1997015' from dual union select '1997017' from dual union select '204429' from dual union select '204431' from dual union select '205791' from dual union select '2059015' from dual union select '2059017' from dual union select '209081' from dual union select '209082' from dual union select '209083' from dual union select '209084' from dual union select '209086' from dual union select '209087' from dual union select '209088' from dual union select '211763' from dual union select '212123' from dual union select '212124' from dual union select '212155' from dual union select '238722' from dual union select '238727' from dual union select '238729' from dual union select '238730' from dual union select '241112' from dual union select '241113' from dual union select '242501' from dual union select '244230' from dual union select '244231' from dual union select '244239' from dual union select '244240' from dual union select '246018' from dual union select '246019' from dual union select '248140' from dual union select '248141' from dual union select '251272' from dual union select '280611' from dual union select '282479' from dual union select '283855' from dual union select '284458' from dual union select '284534' from dual union select '308351' from dual union select '308769' from dual union select '310710' from dual union select '310713' from dual union select '310723' from dual union select '310732' from dual union select '310733' from dual union select '310734' from dual union select '310739' from dual union select '310741' from dual union select '313410' from dual union select '313732' from dual union select '313733' from dual union select '313734' from dual union select '313735' from dual union select '313737' from dual union select '313738' from dual union select '313739' from dual union select '314013' from dual union select '314279' from dual union select '314280' from dual union select '321208' from dual union select '349308' from dual union select '351111' from dual union select '352081' from dual union select '352102' from dual union select '370743' from dual union select '371679' from dual union select '371810' from dual union select '372012' from dual union select '374319' from dual union select '374320' from dual union select '374638' from dual union select '376834' from dual union select '381158' from dual union select '389189' from dual union select '402248' from dual union select '402249' from dual union select '404141' from dual union select '404142' from dual union select '404143' from dual union select '404144' from dual union select '404146' from dual union select '404147' from dual union select '404148' from dual union select '404259' from dual union select '404260' from dual union select '415379' from dual union select '5224' from dual union select '540217' from dual union select '542824' from dual union select '545076' from dual union select '562130' from dual union select '562550' from dual union select '581236' from dual union select '60819' from dual union select '616862' from dual union select '616912' from dual union select '645887' from dual union select '67031' from dual union select '67108' from dual union select '67109' from dual union select '69646' from dual union select '727382' from dual union select '727383' from dual union select '727384' from dual union select '727559' from dual union select '727560' from dual union select '727562' from dual union select '727563' from dual union select '727564' from dual union select '727565' from dual union select '727566' from dual union select '727567' from dual union select '727568' from dual union select '727718' from dual union select '727719' from dual union select '727722' from dual union select '727723' from dual union select '727724' from dual union select '727725' from dual union select '727726' from dual union select '727727' from dual union select '727728' from dual union select '727729' from dual union select '727730' from dual union select '727778' from dual union select '727831' from dual union select '727832' from dual union select '727834' from dual union select '727838' from dual union select '727851' from dual union select '727859' from dual union select '727860' from dual union select '727861' from dual union select '727878' from dual union select '727880' from dual union select '727881' from dual union select '727882' from dual union select '727883' from dual union select '727884' from dual union select '727888' from dual union select '727892' from dual union select '727920' from dual union select '727922' from dual union select '727926' from dual union select '729968' from dual union select '729969' from dual union select '729970' from dual union select '729971' from dual union select '729972' from dual union select '729973' from dual union select '729974' from dual union select '729976' from dual union select '730002' from dual union select '746573' from dual union select '746574' from dual union select '753111' from dual union select '753112' from dual union select '753113' from dual union select '759595' from dual union select '759596' from dual union select '759597' from dual union select '759598' from dual union select '759599' from dual union select '75960' from dual union select '759600' from dual union select '759601' from dual union select '792060' from dual union select '795798' from dual union select '827000' from dual union select '827001' from dual union select '827003' from dual union select '827069' from dual union select '827099' from dual union select '829884' from dual union select '829885' from dual union select '829886' from dual union select '829888' from dual union select '830698' from dual union select '848335' from dual union select '848339' from dual union select '849297' from dual union select '849298' from dual union select '849299' from dual union select '849300' from dual union select '849301' from dual union select '849312' from dual union select '849313' from dual union select '849317' from dual union select '849333' from dual union select '849337' from dual union select '849338' from dual union select '849339' from dual union select '849340' from dual union select '849341' from dual union select '849342' from dual union select '849344' from dual union select '849699' from dual union select '849702' from dual union select '849710' from dual union select '849712' from dual union select '849715' from dual union select '849718' from dual union select '849722' from dual union select '849726' from dual union select '849764' from dual union select '849770' from dual union select '849776' from dual union select '849814' from dual union select '854228' from dual union select '854232' from dual union select '854235' from dual union select '854236' from dual union select '854238' from dual union select '854239' from dual union select '854241' from dual union select '854242' from dual union select '854245' from dual union select '854247' from dual union select '854248' from dual union select '854249' from dual union select '854252' from dual union select '854253' from dual union select '854255' from dual union select '854256' from dual union select '855288' from dual union select '855290' from dual union select '855292' from dual union select '855296' from dual union select '855298' from dual union select '855300' from dual union select '855302' from dual union select '855304' from dual union select '855306' from dual union select '855308' from dual union select '855312' from dual union select '855314' from dual union select '855316' from dual union select '855318' from dual union select '855320' from dual union select '855322' from dual union select '855324' from dual union select '855326' from dual union select '855328' from dual union select '855332' from dual union select '855334' from dual union select '855336' from dual union select '855338' from dual union select '855340' from dual union select '855342' from dual union select '855344' from dual union select '855346' from dual union select '855348' from dual union select '855350' from dual union select '857253' from dual union select '857255' from dual union select '857257' from dual union select '857259' from dual union select '857261' from dual union select '857645' from dual union select '861356' from dual union select '861358' from dual union select '861360' from dual union select '861362' from dual union select '861363' from dual union select '861364' from dual union select '861365' from dual union select '861366' from dual union select '978713' from dual union select '978715' from dual union select '978717' from dual union select '978718' from dual union select '978719' from dual union select '978720' from dual union select '978721' from dual union select '978722' from dual union select '978723' from dual union select '978725' from dual union select '978727' from dual union select '978733' from dual union select '978735' from dual union select '978736' from dual union select '978737' from dual union select '978738' from dual union select '978740' from dual union select '978741' from dual union select '978744' from dual union select '978745' from dual union select '978746' from dual union select '978747' from dual union select '978755' from dual union select '978757' from dual union select '978759' from dual union select '978761' from dual union select '978777' from dual union select '978778' from dual) t
		union select 'COVIDVIRAL', c from (select '108766' c from dual union select '1236627' from dual union select '1236628' from dual union select '1236632' from dual union select '1298334' from dual union select '1359269' from dual union select '1359271' from dual union select '1486197' from dual union select '1486198' from dual union select '1486200' from dual union select '1486202' from dual union select '1486203' from dual union select '1487498' from dual union select '1487500' from dual union select '1863148' from dual union select '1992160' from dual union select '207406' from dual union select '248109' from dual union select '248110' from dual union select '248112' from dual union select '284477' from dual union select '284640' from dual union select '311368' from dual union select '311369' from dual union select '312817' from dual union select '312818' from dual union select '352007' from dual union select '352337' from dual union select '373772' from dual union select '373773' from dual union select '373774' from dual union select '374642' from dual union select '374643' from dual union select '376293' from dual union select '378671' from dual union select '460132' from dual union select '539485' from dual union select '544400' from dual union select '597718' from dual union select '597722' from dual union select '597729' from dual union select '597730' from dual union select '602770' from dual union select '616129' from dual union select '616131' from dual union select '616133' from dual union select '643073' from dual union select '643074' from dual union select '670026' from dual union select '701411' from dual union select '701413' from dual union select '746645' from dual union select '746647' from dual union select '754738' from dual union select '757597' from dual union select '757598' from dual union select '757599' from dual union select '757600' from dual union select '790286' from dual union select '794610' from dual union select '795742' from dual union select '795743' from dual union select '824338' from dual union select '824876' from dual union select '831868' from dual union select '831870' from dual union select '847330' from dual union select '847741' from dual union select '847745' from dual union select '847749' from dual union select '850455' from dual union select '850457' from dual union select '896790' from dual union select '902312' from dual union select '902313' from dual union select '9344' from dual ) t
		union select 'DIURETIC', c from (select '392534' c from dual union select '4109' from dual union select '392464' from dual union select '33770' from dual union select '104220' from dual union select '104222' from dual union select '1112201' from dual union select '132604' from dual union select '1488537' from dual union select '1546054' from dual union select '1546056' from dual union select '1719285' from dual union select '1719286' from dual union select '1719290' from dual union select '1719291' from dual union select '1727568' from dual union select '1727569' from dual union select '1727572' from dual union select '1729520' from dual union select '1729521' from dual union select '1729523' from dual union select '1729527' from dual union select '1729528' from dual union select '1808' from dual union select '197417' from dual union select '197418' from dual union select '197419' from dual union select '197730' from dual union select '197731' from dual union select '197732' from dual union select '198369' from dual union select '198370' from dual union select '198371' from dual union select '198372' from dual union select '199610' from dual union select '200801' from dual union select '200809' from dual union select '204154' from dual union select '205488' from dual union select '205489' from dual union select '205490' from dual union select '205732' from dual union select '208076' from dual union select '208078' from dual union select '208080' from dual union select '208081' from dual union select '208082' from dual union select '248657' from dual union select '250044' from dual union select '250660' from dual union select '251308' from dual union select '252484' from dual union select '282452' from dual union select '282486' from dual union select '310429' from dual union select '313988' from dual union select '371157' from dual union select '371158' from dual union select '372280' from dual union select '372281' from dual union select '374168' from dual union select '374368' from dual union select '38413' from dual union select '404018' from dual union select '4603' from dual union select '545041' from dual union select '561969' from dual union select '630032' from dual union select '630035' from dual union select '645036' from dual union select '727573' from dual union select '727574' from dual union select '727575' from dual union select '727845' from dual union select '876422' from dual union select '95600' from dual ) t
		union select 'HCQ', c from (select '1116758' c from dual union select '1116760' from dual union select '1117346' from dual union select '1117351' from dual union select '1117353' from dual union select '1117531' from dual union select '197474' from dual union select '197796' from dual union select '202317' from dual union select '213378' from dual union select '226388' from dual union select '2393' from dual union select '249663' from dual union select '250175' from dual union select '261104' from dual union select '370656' from dual union select '371407' from dual union select '5521' from dual union select '755624' from dual union select '755625' from dual union select '756408' from dual union select '979092' from dual union select '979094' from dual ) t
		union select 'ILI', c from (select '1441526' c from dual union select '1441527' from dual union select '1441530' from dual union select '1535218' from dual union select '1535242' from dual union select '1535247' from dual union select '1657973' from dual union select '1657974' from dual union select '1657976' from dual union select '1657979' from dual union select '1657980' from dual union select '1657981' from dual union select '1657982' from dual union select '1658131' from dual union select '1658132' from dual union select '1658135' from dual union select '1658139' from dual union select '1658141' from dual union select '1923319' from dual union select '1923332' from dual union select '1923333' from dual union select '1923338' from dual union select '1923345' from dual union select '1923347' from dual union select '2003754' from dual union select '2003755' from dual union select '2003757' from dual union select '2003766' from dual union select '2003767' from dual union select '351141' from dual union select '352056' from dual union select '612865' from dual union select '72435' from dual union select '727708' from dual union select '727711' from dual union select '727714' from dual union select '727715' from dual union select '895760' from dual union select '895764' from dual ) t
		union select 'INTERFERON', c from (select '120608' c from dual union select '1650893' from dual union select '1650894' from dual union select '1650896' from dual union select '1650922' from dual union select '1650940' from dual union select '1651307' from dual union select '1721323' from dual union select '198360' from dual union select '207059' from dual union select '351270' from dual union select '352297' from dual union select '378926' from dual union select '403986' from dual union select '72257' from dual union select '731325' from dual union select '731326' from dual union select '731328' from dual union select '731330' from dual union select '860244' from dual) t
		union select 'SIANES', c from (select '106517' c from dual union select '1087926' from dual union select '1188478' from dual union select '1234995' from dual union select '1242617' from dual union select '1249681' from dual union select '1301259' from dual union select '1313988' from dual union select '1373737' from dual union select '1486837' from dual union select '1535224' from dual union select '1535226' from dual union select '1535228' from dual union select '1535230' from dual union select '1551393' from dual union select '1551395' from dual union select '1605773' from dual union select '1666776' from dual union select '1666777' from dual union select '1666797' from dual union select '1666798' from dual union select '1666800' from dual union select '1666814' from dual union select '1666821' from dual union select '1666823' from dual union select '1718899' from dual union select '1718900' from dual union select '1718902' from dual union select '1718906' from dual union select '1718907' from dual union select '1718909' from dual union select '1718910' from dual union select '1730193' from dual union select '1730194' from dual union select '1730196' from dual union select '1732667' from dual union select '1732668' from dual union select '1732674' from dual union select '1788947' from dual union select '1808216' from dual union select '1808217' from dual union select '1808219' from dual union select '1808222' from dual union select '1808223' from dual union select '1808224' from dual union select '1808225' from dual union select '1808234' from dual union select '1808235' from dual union select '1862110' from dual union select '198383' from dual union select '199211' from dual union select '199212' from dual union select '199775' from dual union select '2050125' from dual union select '2057964' from dual union select '206967' from dual union select '206970' from dual union select '206972' from dual union select '207793' from dual union select '207901' from dual union select '210676' from dual union select '210677' from dual union select '238082' from dual union select '238083' from dual union select '238084' from dual union select '240606' from dual union select '259859' from dual union select '284397' from dual union select '309710' from dual union select '311700' from dual union select '311701' from dual union select '311702' from dual union select '312674' from dual union select '319864' from dual union select '372528' from dual union select '372922' from dual union select '375623' from dual union select '376856' from dual union select '377135' from dual union select '377219' from dual union select '377483' from dual union select '379133' from dual union select '404091' from dual union select '404092' from dual union select '404136' from dual union select '422410' from dual union select '446503' from dual union select '48937' from dual union select '584528' from dual union select '584530' from dual union select '6130' from dual union select '631205' from dual union select '68139' from dual union select '6960' from dual union select '71535' from dual union select '828589' from dual union select '828591' from dual union select '830752' from dual union select '859437' from dual union select '8782' from dual union select '884675' from dual union select '897073' from dual union select '897077' from dual union select '998210' from dual union select '998211' from dual ) t
		union select 'SICARDIAC', c from (select '7442' c from dual union select '1009216' from dual union select '1045470' from dual union select '1049182' from dual union select '1049184' from dual union select '1052767' from dual union select '106686' from dual union select '106779' from dual union select '106780' from dual union select '1087043' from dual union select '1087047' from dual union select '1090087' from dual union select '1114874' from dual union select '1114880' from dual union select '1114888' from dual union select '11149' from dual union select '1117374' from dual union select '1232651' from dual union select '1232653' from dual union select '1234563' from dual union select '1234569' from dual union select '1234571' from dual union select '1234576' from dual union select '1234578' from dual union select '1234579' from dual union select '1234581' from dual union select '1234584' from dual union select '1234585' from dual union select '1234586' from dual union select '1251018' from dual union select '1251022' from dual union select '1292716' from dual union select '1292731' from dual union select '1292740' from dual union select '1292751' from dual union select '1292887' from dual union select '1299137' from dual union select '1299141' from dual union select '1299145' from dual union select '1299879' from dual union select '1300092' from dual union select '1302755' from dual union select '1305268' from dual union select '1305269' from dual union select '1307224' from dual union select '1358843' from dual union select '1363777' from dual union select '1363785' from dual union select '1363786' from dual union select '1363787' from dual union select '1366958' from dual union select '141848' from dual union select '1490057' from dual union select '1542385' from dual union select '1546216' from dual union select '1546217' from dual union select '1547926' from dual union select '1548673' from dual union select '1549386' from dual union select '1549388' from dual union select '1593738' from dual union select '1658178' from dual union select '1660013' from dual union select '1660014' from dual union select '1660016' from dual union select '1661387' from dual union select '1666371' from dual union select '1666372' from dual union select '1666374' from dual union select '1721536' from dual union select '1743862' from dual union select '1743869' from dual union select '1743871' from dual union select '1743877' from dual union select '1743879' from dual union select '1743938' from dual union select '1743941' from dual union select '1743950' from dual union select '1743953' from dual union select '1745276' from dual union select '1789858' from dual union select '1791839' from dual union select '1791840' from dual union select '1791842' from dual union select '1791854' from dual union select '1791859' from dual union select '1791861' from dual union select '1812167' from dual union select '1812168' from dual union select '1812170' from dual union select '1870205' from dual union select '1870207' from dual union select '1870225' from dual union select '1870230' from dual union select '1870232' from dual union select '1939322' from dual union select '198620' from dual union select '198621' from dual union select '198786' from dual union select '198787' from dual union select '198788' from dual union select '1989112' from dual union select '1989117' from dual union select '1991328' from dual union select '1991329' from dual union select '1999003' from dual union select '1999006' from dual union select '1999007' from dual union select '1999012' from dual union select '204395' from dual union select '204843' from dual union select '209217' from dual union select '2103181' from dual union select '2103182' from dual union select '2103184' from dual union select '211199' from dual union select '211200' from dual union select '211704' from dual union select '211709' from dual union select '211712' from dual union select '211714' from dual union select '211715' from dual union select '212343' from dual union select '212770' from dual union select '212771' from dual union select '212772' from dual union select '212773' from dual union select '238217' from dual union select '238218' from dual union select '238219' from dual union select '238230' from dual union select '238996' from dual union select '238997' from dual union select '238999' from dual union select '239000' from dual union select '239001' from dual union select '241033' from dual union select '242969' from dual union select '244284' from dual union select '245317' from dual union select '247596' from dual union select '247940' from dual union select '260687' from dual union select '309985' from dual union select '309986' from dual union select '309987' from dual union select '310011' from dual union select '310012' from dual union select '310013' from dual union select '310116' from dual union select '310117' from dual union select '310127' from dual union select '310132' from dual union select '311705' from dual union select '312395' from dual union select '312398' from dual union select '313578' from dual union select '313967' from dual union select '314175' from dual union select '347930' from dual union select '351701' from dual union select '351702' from dual union select '351982' from dual union select '359907' from dual union select '3616' from dual union select '3628' from dual union select '372029' from dual union select '372030' from dual union select '372031' from dual union select '373368' from dual union select '373369' from dual union select '373370' from dual union select '373372' from dual union select '373375' from dual union select '374283' from dual union select '374570' from dual union select '376521' from dual union select '377281' from dual union select '379042' from dual union select '387789' from dual union select '392099' from dual union select '393309' from dual union select '3992' from dual union select '404093' from dual union select '477358' from dual union select '477359' from dual union select '52769' from dual union select '542391' from dual union select '542655' from dual union select '542674' from dual union select '562501' from dual union select '562502' from dual union select '562592' from dual union select '584580' from dual union select '584582' from dual union select '584584' from dual union select '584588' from dual union select '602511' from dual union select '603259' from dual union select '603276' from dual union select '603915' from dual union select '617785' from dual union select '669267' from dual union select '672683' from dual union select '672685' from dual union select '672891' from dual union select '692479' from dual union select '700414' from dual union select '704955' from dual union select '705163' from dual union select '705164' from dual union select '705170' from dual union select '727310' from dual union select '727316' from dual union select '727345' from dual union select '727347' from dual union select '727373' from dual union select '727386' from dual union select '727410' from dual union select '727842' from dual union select '727843' from dual union select '727844' from dual union select '746206' from dual union select '746207' from dual union select '7512' from dual union select '8163' from dual union select '827706' from dual union select '864089' from dual union select '880658' from dual union select '8814' from dual union select '883806' from dual union select '891437' from dual union select '891438' from dual ) t
	) t;
commit;
-- Remdesivir defined separately since many sites will have custom codes (optional)
insert into COVID_MED_MAP
	select 'REMDESIVIR', 'RxNorm', 'RxNorm:2284718' from dual 
        union 
    select 'REMDESIVIR', 'RxNorm', 'RxNorm:2284960' from dual 
        union 
    select 'REMDESIVIR', 'Custom', 'ACT|LOCAL:REMDESIVIR' from dual; 
commit;

-- Use the concept_dimension to get an expanded list of medication codes (optional)
-- Uncomment the query below to run this as part of the script.
-- Change "\ACT\Medications\%" to the root path of medications in your ontology.
-- This will pull in additional medications based on your existing mappings.
-- It will find paths corresponding to concepts already in the #med_map table,
--   and then find all the concepts corresponding to child paths.
-- WARNING: This query might take several minutes to run. If it is taking more
--   than an hour, then stop the query and contact us about alternative approaches.
/*
create table COVID_MED_PATHS AS
select concept_path, concept_cd
	from concept_dimension
	where concept_path like '\ACT\Medications\%'
		and concept_cd in (select concept_cd from observation_fact); 
alter table COVID_MED_PATHS add constraint COVID_MEDPATHS_PK primary key (concept_path);
alter table COVID_MED_PATHS add med_class varchar(50);
insert into COVID_MED_PATHS
	select distinct 'Expand', d.concept_cd, m.med_class
	from COVID_MED_MAP m
		inner join concept_dimension c
			on m.local_med_code = c.concept_cd
		inner join COVID_MED_PATHS d
			on d.concept_path like c.concept_path||'%'
	where not exists (
		select *
		from COVID_MED_MAP t
		where t.med_class = m.med_class and t.local_med_code = d.concept_cd
	);
commit;    
*/

--##############################################################################
--### Most sites will not have to modify any SQL beyond this point.
--### However, review the queries to see if you need to customize them
--###   for special logic, privacy, etc.
--##############################################################################



--******************************************************************************
--******************************************************************************
--*** Define the COVID cohort (COVID postive test + admitted)
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create the list of COVID-19 positive patients.
-- Use the earliest date where the patient is known to be COVID positive,
--   for example, a COVID positive test result.
--------------------------------------------------------------------------------
create table covid_pos_patients (
	patient_num int not null,
	covid_pos_date date not null,
    constraint covid_pospatients_pk primary key (patient_num, covid_pos_date)
);

insert into covid_pos_patients
	select patient_num, cast(min(start_date) as date) covid_pos_date
	from observation_fact f
		inner join covid_code_map m
			on f.concept_cd = m.local_code and m.code = 'covidpos'
	group by patient_num;
commit;    

--------------------------------------------------------------------------------
-- Create a list of dates when patients were inpatient starting one week  
--   before their COVID pos date.
--------------------------------------------------------------------------------
create table covid_admissions (
	patient_num int not null,
	admission_date date not null,
	discharge_date date not null,
    constraint covid_admissions primary key (patient_num, admission_date, discharge_date)
);

insert into covid_admissions
	select distinct v.patient_num, cast(start_date as date), cast(coalesce(end_date,current_date) as date)
	from visit_dimension v
		inner join covid_pos_patients p
			on v.patient_num=p.patient_num 
				and v.start_date >= (trunc(p.covid_pos_date)-7)
		inner join covid_code_map m
			on v.inout_cd = m.local_code and m.code = 'inpatient';
commit;

--------------------------------------------------------------------------------
-- Get the list of patients who will be the covid cohort.
-- These will be patients who had an admission between 7 days before and
--   14 days after their covid positive test date.
--------------------------------------------------------------------------------
create table covid_cohort (
	patient_num number(8,0) not null,
	admission_date date,
	severe number(8,0),
	severe_date date,
	death_date date,
    constraint covid_cohort primary key (patient_num)
);

insert into covid_cohort
	select p.patient_num, min(admission_date) admission_date, 0, null, null
	from covid_pos_patients p
		inner join covid_admissions a
			on p.patient_num = a.patient_num	
				and a.admission_date <= (trunc(covid_pos_date)+14)
	group by p.patient_num;
commit;

--******************************************************************************
--******************************************************************************
--*** Determine which patients had severe disease or died
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Flag the patients who had severe disease anytime since admission.
--------------------------------------------------------------------------------
create table covid_severe_patients (
	patient_num number(8,0) not null,
	severe_date date
);
-- Get a list of patients with severe codes
-- WARNING: This query might take a few minutes to run.
insert into covid_severe_patients
	select f.patient_num, min(start_date) start_date
	from observation_fact f
		inner join covid_cohort c
			on f.patient_num = c.patient_num and f.start_date >= c.admission_date
		cross apply covid_config x
	where 
		-- Any PaCO2 or PaO2 lab test
		f.concept_cd in (select local_lab_code from covid_lab_map where loinc in ('2019-8','2703-7'))
		-- Any severe medication
		or f.concept_cd in (select local_med_code from covid_med_map where med_class in ('SIANES','SICARDIAC'))
		-- Acute respiratory distress syndrome (diagnosis)
		or f.concept_cd in (code_prefix_icd10cm||'J80', code_prefix_icd9cm||'518.82')
		-- Ventilator associated pneumonia (diagnosis)
		or f.concept_cd in (code_prefix_icd10cm||'J95.851', code_prefix_icd9cm||'997.31')
		-- Insertion of endotracheal tube (procedure)
		or f.concept_cd in (code_prefix_icd10pcs||'0BH17EZ', code_prefix_icd9proc||'96.04')
		-- Invasive mechanical ventilation (procedure)
		or regexp_like(f.concept_cd , code_prefix_icd10pcs||'5A09[345]{1}[A-Z0-9]?') --Converted to ORACLE Regex
		or regexp_like(f.concept_cd , code_prefix_icd9proc||'96.7[012]{1}') --Converted to ORACLE Regex
	group by f.patient_num;
commit;    

-- Update the covid_cohort table to flag severe patients 
MERGE INTO COVID_COHORT c
USING (select patient_num, min(severe_date) severe_date
			from covid_severe_patients
			group by patient_num) s
ON (c.patient_num=s.patient_num)
WHEN MATCHED THEN UPDATE SET c.severe = 1, c.severe_date = s.severe_date;
commit;

--------------------------------------------------------------------------------
-- Add death dates to patients who have died.
--------------------------------------------------------------------------------
begin
    if exists (select * from covid_config where death_data_accurate = 1) then 
        -- Get the death date from the patient_dimension table.
        update covid_cohort c
            set c.death_date = (
                select 
                    case when p.death_date > coalesce(severe_date,admission_date) 
                    then p.death_date 
                    else coalesce(severe_date,admission_date) end
                from covid_cohort c
                   inner join patient_dimension p on p.patient_num = c.patient_num
            )
            where exists (select c.patient_num from patient_dimension p where p.patient_num = c.patient_num and (p.death_date is not null or p.vital_status_cd in ('Y'))); 
        commit;
        -- Check that there aren't more recent facts for the deceased patients.
        update covid_cohort c
            set c.death_date = (
                select max(f.start_date) death_date
                from covid_cohort p
                   inner join observation_fact f
                      on f.patient_num = p.patient_num
                where p.death_date is not null and f.start_date > p.death_date
            )
            where c.death_date is not null; 
        commit;
    end if;            
end;


--******************************************************************************
--******************************************************************************
--*** Precompute some temp tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create a list of dates since the first case.
--------------------------------------------------------------------------------
create table covid_date_list_temp as
with n as (
    select 0 n from dual
        union all
    select 1 from dual
        union all
    select 2 from dual
        union all
    select 3 from dual
        union all
    select 4 from dual
        union all
    select 5 from dual
        union all
    select 6 from dual
        union all
    select 7 from dual
        union all
    select 8 from dual
        union all
    select 9 from dual
)
select d
from (
    select nvl(cast((p.s + numtodsinterval(((a.n + (10 * b.n)) + (100 * c.n)),'day')) as date), '01-JAN-2020') d
    from (select min(admission_date) s from covid_cohort) p
        cross join n a cross join n b cross join n c
) l
where d<=current_timestamp;
alter table covid_date_list_temp add constraint temp_datelist_pk primary key (d);
--------------------------------------------------------------------------------
-- Create a table with patient demographics.
--------------------------------------------------------------------------------
create table covid_demographics_temp (
	patient_num number(8,0),
	sex varchar(10),
	age_group varchar(20),
	race varchar(30)
);
-- Get patients' sex
insert into covid_demographics_temp (patient_num, sex)
	select patient_num, m.code
	from patient_dimension p
		inner join covid_code_map m
			on p.sex_cd = m.local_code
				and m.code in ('male','female')
	where patient_num in (select patient_num from covid_cohort);
commit;    
-- Get patients' age
insert into covid_demographics_temp (patient_num, age_group)
	select patient_num,
        -- uncomment if you pre-compute age on patient_dimension
		/*(case
			when age_in_years_num between 0 and 2 then '00to02'
			when age_in_years_num between 3 and 5 then '03to05'
			when age_in_years_num between 6 and 11 then '06to11'
			when age_in_years_num between 12 and 17 then '12to17'
			when age_in_years_num between 18 and 25 then '18to25'
			when age_in_years_num between 26 and 49 then '26to49'
			when age_in_years_num between 50 and 69 then '50to69'
			when age_in_years_num between 70 and 79 then '70to79'
			when age_in_years_num >= 80 then '80plus'
			else 'other' end) age*/
        (case
			when floor(months_between(sysdate, birth_date)/12) between 0 and 2 then '00to02'
			when floor(months_between(sysdate, birth_date)/12) between 3 and 5 then '03to05'
			when floor(months_between(sysdate, birth_date)/12) between 6 and 11 then '06to11'
			when floor(months_between(sysdate, birth_date)/12) between 12 and 17 then '12to17'
			when floor(months_between(sysdate, birth_date)/12) between 18 and 25 then '18to25'
			when floor(months_between(sysdate, birth_date)/12) between 26 and 49 then '26to49'
			when floor(months_between(sysdate, birth_date)/12) between 50 and 69 then '50to69'
			when floor(months_between(sysdate, birth_date)/12) between 70 and 79 then '70to79'
			when floor(months_between(sysdate, birth_date)/12) >= 80 then '80plus'
			else 'other' end) age
	from patient_dimension
	where patient_num in (select patient_num from covid_cohort);
commit;    
-- Get patients' race(s)
-- (race from patient_dimension)
insert into covid_demographics_temp (patient_num, race)
	select p.patient_num, m.code
	from covid_config x
		cross join patient_dimension p
		inner join covid_code_map m
			on p.race_cd = m.local_code
	where p.patient_num in (select patient_num from covid_cohort)
		and x.include_race = 1
		and (
			(x.race_in_fact_table = 0 and m.code in ('american_indian','asian','black','hawaiian_pacific_islander','white'))
			or
			(x.hispanic_in_fact_table = 0 and m.code in ('hispanic_latino'))
		)
;commit;

-- (race from observation_fact)
insert into covid_demographics_temp (patient_num, race)
	select f.patient_num, m.code
	from covid_config x
		cross join observation_fact f
		inner join covid_code_map m
			on f.concept_cd = m.local_code
	where f.patient_num in (select patient_num from covid_cohort)
		and x.include_race = 1
		and (
			(x.race_in_fact_table = 1 and m.code in ('american_indian','asian','black','hawaiian_pacific_islander','white'))
			or
			(x.hispanic_in_fact_table = 1 and m.code in ('hispanic_latino'))
		)
;commit;        
-- Make sure every patient has a sex, age_group, and race
insert into covid_demographics_temp (patient_num, sex, age_group, race)
	select patient_num, 'other', null, null
		from covid_cohort
		where patient_num not in (select patient_num from covid_demographics_temp where sex is not null)
	union all
	select patient_num, null, 'other', null
		from covid_cohort
		where patient_num not in (select patient_num from covid_demographics_temp where age_group is not null)
	union all
	select patient_num, null, null, 'other'
		from covid_cohort
		where patient_num not in (select patient_num from covid_demographics_temp where race is not null)
;commit;

--******************************************************************************
--******************************************************************************
--*** Create data tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Create DailyCounts table.
--------------------------------------------------------------------------------
create table covid_daily_counts (
	siteid varchar(50) not null,
	calendar_date date not null,
	cumulative_patients_all numeric(8,0),
	cumulative_patients_severe numeric(8,0),
	cumulative_patients_dead numeric(8,0),
	num_pat_in_hosp_on_date numeric(8,0), -- num_patients_in_hospital_on_this_date: shortened to under 128 bytes
	num_pat_in_hospsevere_on_date numeric(8,0), --num_patients_in_hospital_and_severe_on_this_date: shortened to under 128 bytes
    constraint covid_dlycounts_pk primary key (calendar_date)
);

insert into covid_daily_counts
	select '' siteid, d.*,
		(select count(distinct c.patient_num)
			from covid_admissions p
				inner join covid_cohort c
					on p.patient_num=c.patient_num
			where p.admission_date>=c.admission_date
				and p.admission_date<=d.d and p.discharge_date>=d.d
		) num_pat_in_hosp_on_date,
		(select count(distinct c.patient_num)
			from covid_admissions p
				inner join covid_cohort c
					on p.patient_num=c.patient_num
			where p.admission_date>=c.admission_date
				and p.admission_date<=d.d and p.discharge_date>=d.d
				and c.severe_date<=d.d
		) num_pat_in_hospsevere_on_date
	from (
		select d.d,
			sum(case when c.admission_date<=d.d then 1 else 0 end) cumulative_patients_all,
			sum(case when c.severe_date<=d.d then 1 else 0 end) cumulative_patients_severe,
			sum(case when c.death_date<=d.d then 1 else 0 end) cumulative_patients_dead
		from covid_date_list_temp d
			cross join covid_cohort c
		group by d.d
	) d
;commit;    
-- Set cumulative_patients_dead = -999 if you do not have accurate death data. 
update covid_daily_counts
	set cumulative_patients_dead = -999
	where exists (select * from covid_config where death_data_accurate = 0)
;commit;    

--------------------------------------------------------------------------------
-- Create ClinicalCourse table.
--------------------------------------------------------------------------------
create table covid_clinical_course (
	siteid varchar(50) not null,
	days_since_admission int not null,
	num_pat_all_cur_in_hosp numeric(8,0),  --num_patients_all_still_in_hospital: shortened to under 128 bytes
	num_pat_ever_severe_cur_hosp numeric(8,0),  --num_patients_ever_severe_still_in_hospital: shortened to under 128 bytes
    constraint covid_clinicalcourse_pk primary key (days_since_admission)
);
insert into covid_clinical_course
	select '' siteid, days_since_admission, 
		count(*),
		sum(severe)
	from (
		select distinct trunc(c.admission_date)-trunc(d.d) days_since_admission, 
			c.patient_num, severe
		from covid_date_list_temp d
			inner join covid_admissions p
				on p.admission_date<=d.d and p.discharge_date>=d.d
			inner join covid_cohort c
				on p.patient_num=c.patient_num and p.admission_date>=c.admission_date
	) t
	group by days_since_admission
;commit;    

--------------------------------------------------------------------------------
-- Create Demographics table.
--------------------------------------------------------------------------------
create table covid_demographics (
	siteid varchar(50) not null,
	sex varchar(10) not null,
	age_group varchar(20) not null,
	race varchar(30) not null,
	num_patients_all numeric(8,0),
	num_patients_ever_severe numeric(8,0),
    constraint covid_demographics_pk primary key (sex, age_group, race)
);
insert into covid_demographics
	select '' siteid, sex, age_group, race, count(*), sum(severe)
	from covid_cohort c
		inner join (
			select patient_num, sex from covid_demographics_temp where sex is not null
			union all
			select patient_num, 'all' from covid_cohort
		) s on c.patient_num=s.patient_num
		inner join (
			select patient_num, age_group from covid_demographics_temp where age_group is not null
			union all
			select patient_num, 'all' from covid_cohort
		) a on c.patient_num=a.patient_num
		inner join (
			select patient_num, race from covid_demographics_temp where race is not null
			union all
			select patient_num, 'all' from covid_cohort
		) r on c.patient_num=r.patient_num
	group by sex, age_group, race
;commit;    
-- Set counts = -999 if not including race.
update covid_demographics
	set num_patients_all = -999, num_patients_ever_severe = -999
	where exists (select * from covid_config where include_race = 0)
;commit;
--------------------------------------------------------------------------------
-- Create Labs table.
--------------------------------------------------------------------------------
create table covid_labs (
	siteid varchar(50) not null,
	loinc varchar(20) not null,
	days_since_admission int not null,
	units varchar(20),
	num_patients_all numeric(8,0),
	mean_value_all float,
	stdev_value_all float,
	mean_log_value_all float,
	stdev_log_value_all float,
	num_patients_ever_severe numeric(8,0),
	mean_value_ever_severe float,
	stdev_value_ever_severe float,
	mean_log_value_ever_severe float,
	stdev_log_value_ever_severe float,
    constraint covid_labs_pk primary key (loinc, days_since_admission)
);
insert into covid_labs
	select '' siteid, loinc, days_since_admission, lab_units,
		count(*), 
		avg(val), 
		coalesce(stddev(val),0),
		avg(logval), 
		coalesce(stddev(logval),0),
		sum(severe), 
		(case when sum(severe)=0 then -999 else avg(case when severe=1 then val else null end) end), 
		(case when sum(severe)=0 then -999 else coalesce(stddev(case when severe=1 then val else null end),0) end),
		(case when sum(severe)=0 then -999 else avg(case when severe=1 then logval else null end) end), 
		(case when sum(severe)=0 then -999 else coalesce(stddev(case when severe=1 then logval else null end),0) end)
	from (
		select loinc, lab_units, patient_num, severe, days_since_admission, 
			avg(val) val, 
			avg(ln(val+0.5)) logval -- natural log (ln), not log base 10
		from (
			select l.loinc, l.lab_units, f.patient_num, p.severe,
				trunc(p.admission_date) - trunc(f.start_date) days_since_admission,
				f.nval_num*l.scale_factor val
			from observation_fact f
				inner join covid_cohort p 
					on f.patient_num=p.patient_num
				inner join covid_lab_map l
					on f.concept_cd=l.local_lab_code
			where l.local_lab_code is not null
				and f.nval_num is not null
				and f.nval_num >= 0
				and f.start_date >= p.admission_date
				and l.loinc not in ('2019-8','2703-7')
		) t
		group by loinc, lab_units, patient_num, severe, days_since_admission
	) t
	group by loinc, days_since_admission, lab_units
;commit;    

--------------------------------------------------------------------------------
-- Create Diagnosis table.
-- * Select all ICD9 and ICD10 codes.
-- * Note that just the left 3 characters of the ICD codes should be used.
-- * Customize this query if your ICD codes do not have a prefix.
--------------------------------------------------------------------------------
create table covid_diagnoses (
	siteid varchar(50) not null,
	icd_code_3chars varchar(10) not null,
	icd_version int not null,
	num_pat_all_before_admission numeric(8,0), --NUM_PATIENTS_ALL_BEFORE_ADMISSION: shortened to under 128 bytes
	num_pat_all_since_admission numeric(8,0), --NUM_PATIENTS_all_SINCE_ADMISSION: shortened to under 128 bytes
	num_pat_ever_severe_before_adm numeric(8,0), --num_patients_ever_severe_before_admission: shortened to under 128 bytes
	num_pat_ever_severe_since_adm numeric(8,0), --num_patients_ever_severe_since_admission: shortened to under 128 bytes
    constraint covid_diagnoses_pk primary key (icd_code_3chars, icd_version)
);
insert into covid_diagnoses
	select '' siteid, icd_code_3chars, icd_version,
		sum(before_admission), 
		sum(since_admission), 
		sum(severe*before_admission), 
		sum(severe*since_admission)
	from (
		-- ICD9
		select distinct p.patient_num, p.severe, 9 icd_version,
			substr(substr(f.concept_cd, length(code_prefix_icd9cm)+1, 999), 1, 3) icd_code_3chars,
			(case when f.start_date <= (trunc(p.admission_date)-15) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from covid_config x
			cross join observation_fact f
			inner join covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= (trunc(p.admission_date)-365)
		where concept_cd like code_prefix_icd9cm||'%' and code_prefix_icd9cm <> ''
		-- ICD10
		union all
		select distinct p.patient_num, p.severe, 10 icd_version,
			substr(substr(f.concept_cd, length(code_prefix_icd10cm)+1, 999), 1, 3) icd_code_3chars,
			(case when f.start_date <= (trunc(p.admission_date)-15) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from covid_config x
			cross join observation_fact f
			inner join covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= (trunc(p.admission_date)-365)
		where concept_cd like code_prefix_icd10cm||'%' and code_prefix_icd10cm <> ''
	) t
	group by icd_code_3chars, icd_version;
commit;    

--------------------------------------------------------------------------------
-- Create Medications table.
--------------------------------------------------------------------------------
create table covid_medications (
	siteid varchar(50) not null,
	med_class varchar(20) not null,
	num_pat_all_before_admission numeric(8,0),
	num_pat_all_since_admission numeric(8,0),
	num_pat_ever_severe_before_adm numeric(8,0), --num_patients_ever_severe_before_admission: shortened to under 128 bytes
	num_pat_ever_severe_since_adm numeric(8,0), --num_patients_ever_severe_since_admission: shortened to under 128 bytes
    constraint covid_medications primary key (med_class)
);
insert into covid_medications
	select '' siteid, med_class,
		sum(before_admission), 
		sum(since_admission), 
		sum(severe*before_admission), 
		sum(severe*since_admission)
	from (
		select distinct p.patient_num, p.severe, m.med_class,	
			(case when f.start_date <= (trunc(p.admission_date)-15) then 1 else 0 end) before_admission,
			(case when f.start_date >= p.admission_date then 1 else 0 end) since_admission
		from observation_fact f
			inner join covid_cohort p 
				on f.patient_num=p.patient_num 
					and f.start_date >= (trunc(p.admission_date)-365)
			inner join covid_med_map m
				on f.concept_cd = m.local_med_code
	) t
	group by med_class;
commit;    


--******************************************************************************
--******************************************************************************
--*** Obfuscate as needed (optional)
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Blur counts by adding a small random number.
--------------------------------------------------------------------------------

declare 
        v_obfuscation_blur numeric(8,0);
begin
    select obfuscation_blur into v_obfuscation_blur from covid_config;
	if v_obfuscation_blur > 0 THEN
        
        update covid_daily_counts
            set cumulative_patients_all = cumulative_patients_all + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                cumulative_patients_severe = cumulative_patients_severe + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                cumulative_patients_dead = cumulative_patients_dead + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_in_hosp_on_date = num_pat_in_hosp_on_date + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_in_hospsevere_on_date = num_pat_in_hospsevere_on_date + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur         
        ;commit;  
        update covid_clinical_course
            set num_pat_all_cur_in_hosp = num_pat_all_cur_in_hosp + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_ever_severe_cur_hosp = num_pat_ever_severe_cur_hosp + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur
        ;commit;
        update covid_demographics
            set num_patients_all = num_patients_all + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_patients_ever_severe = num_patients_ever_severe + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur
        ;commit;
        update covid_labs
            set num_patients_all = num_patients_all + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_patients_ever_severe = num_patients_ever_severe + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur
        ;commit;
        update covid_diagnoses
            set num_pat_all_before_admission = num_pat_all_before_admission + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_all_since_admission = num_pat_all_since_admission + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_ever_severe_before_adm = num_pat_ever_severe_before_adm + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_ever_severe_since_adm = num_pat_ever_severe_since_adm + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur
        ;commit;        
        update covid_medications
            set num_pat_all_before_admission = num_pat_all_before_admission + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_all_since_admission = num_pat_all_since_admission + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_ever_severe_before_adm = num_pat_ever_severe_before_adm + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur,
                num_pat_ever_severe_since_adm = num_pat_ever_severe_since_adm + FLOOR(ABS(OWA_OPT_LOCK.CHECKSUM(sys_guid())/2147483648.0)*(v_obfuscation_blur*2+1)) - v_obfuscation_blur
        ;commit;        
    end if;        
end;

--------------------------------------------------------------------------------
-- Mask small counts with "-99".
--------------------------------------------------------------------------------
declare 
    v_obfuscation_sml_count_mask numeric(8,0); --shortened to under 128 bytes

begin
    select obfuscation_small_count_mask into v_obfuscation_sml_count_mask from covid_config;
	if v_obfuscation_sml_count_mask > 0 THEN
        update covid_daily_counts
            set cumulative_patients_all = (case when cumulative_patients_all<v_obfuscation_sml_count_mask then -99 else cumulative_patients_all end),
                cumulative_patients_severe = (case when cumulative_patients_severe<v_obfuscation_sml_count_mask then -99 else cumulative_patients_severe end),
                cumulative_patients_dead = (case when cumulative_patients_dead<v_obfuscation_sml_count_mask then -99 else cumulative_patients_dead end),
                num_pat_in_hosp_on_date = (case when num_pat_in_hosp_on_date<v_obfuscation_sml_count_mask then -99 else num_pat_in_hosp_on_date end),
                num_pat_in_hospsevere_on_date = (case when num_pat_in_hospsevere_on_date<v_obfuscation_sml_count_mask then -99 else num_pat_in_hospsevere_on_date end)
        ;commit;       
        update covid_clinical_course
            set num_pat_all_cur_in_hosp = (case when num_pat_all_cur_in_hosp<v_obfuscation_sml_count_mask then -99 else num_pat_all_cur_in_hosp end),
                num_pat_ever_severe_cur_hosp = (case when num_pat_ever_severe_cur_hosp<v_obfuscation_sml_count_mask then -99 else num_pat_ever_severe_cur_hosp end)
        ;commit;
        update covid_demographics
            set num_patients_all = (case when num_patients_all<v_obfuscation_sml_count_mask then -99 else num_patients_all end),
                num_patients_ever_severe = (case when num_patients_ever_severe<v_obfuscation_sml_count_mask then -99 else num_patients_ever_severe end)
        ;commit;
        update covid_labs
            set num_patients_all=-99, mean_value_all=-99, stdev_value_all=-99, mean_log_value_all=-99, stdev_log_value_all=-99
            where num_patients_all<v_obfuscation_sml_count_mask
        ;commit;
        update covid_labs
            set num_patients_ever_severe=-99, mean_value_ever_severe=-99, STDEV_VALUE_EVER_SEVERE=-99, mean_log_value_ever_severe=-99, stdev_log_value_ever_severe=-99
            where num_patients_ever_severe<v_obfuscation_sml_count_mask
        ;commit;
        update covid_diagnoses
            set num_pat_all_before_admission = (case when num_pat_all_before_admission<v_obfuscation_sml_count_mask then -99 else num_pat_all_before_admission end),
                num_pat_all_since_admission = (case when num_pat_all_since_admission<v_obfuscation_sml_count_mask then -99 else num_pat_all_since_admission end),
                num_pat_ever_severe_before_adm = (case when num_pat_ever_severe_before_adm<v_obfuscation_sml_count_mask then -99 else num_pat_ever_severe_before_adm end),
                num_pat_ever_severe_since_adm = (case when num_pat_ever_severe_since_adm<v_obfuscation_sml_count_mask then -99 else num_pat_ever_severe_since_adm end)
        ;commit;
        update covid_medications
            set num_pat_all_before_admission = (case when num_pat_all_before_admission<v_obfuscation_sml_count_mask then -99 else num_pat_all_before_admission end),
                num_pat_all_since_admission = (case when num_pat_all_since_admission<v_obfuscation_sml_count_mask then -99 else num_pat_all_since_admission end),
                num_pat_ever_severe_before_adm = (case when num_pat_ever_severe_before_adm<v_obfuscation_sml_count_mask then -99 else num_pat_ever_severe_before_adm end),
                num_pat_ever_severe_since_adm = (case when num_pat_ever_severe_since_adm<v_obfuscation_sml_count_mask then -99 else num_pat_ever_severe_since_adm end)
        ;commit;
        END IF;        
end;

--------------------------------------------------------------------------------
-- To protect obfuscated demographics breakdowns, keep individual sex, age,
--   and race breakdowns, set combinations and the total count to -999.
--------------------------------------------------------------------------------
declare
    v_obfuscate_dem numeric(8,0);
begin
    select obfuscation_demographics into v_obfuscate_dem from covid_config;
    if v_obfuscate_dem > 0 THEN
        update covid_demographics
            set num_patients_all = -999, num_patients_ever_severe = -999
            where (case sex when 'all' then 1 else 0 end)
                +(case race when 'all' then 1 else 0 end)
                +(case age_group when 'all' then 1 else 0 end)<>2
        ;commit;        
    END IF;            
end;

--------------------------------------------------------------------------------
-- Delete small counts.
--------------------------------------------------------------------------------
declare 
    v_obfuscation_sml_cnt_delete numeric(8,0); --v_obfuscation_small_count_delete: shortened to under 128 bytes
begin
    select obfuscation_small_count_delete into v_obfuscation_sml_cnt_delete from covid_config;
    if v_obfuscation_sml_cnt_delete > 0 THEN
        select obfuscation_small_count_mask into v_obfuscation_sml_cnt_delete from covid_config;
        delete from covid_daily_counts where cumulative_patients_all<v_obfuscation_sml_cnt_delete;commit;
        delete from covid_clinical_course where num_pat_all_cur_in_hosp<v_obfuscation_sml_cnt_delete;commit;
        delete from covid_labs where num_patients_all<v_obfuscation_sml_cnt_delete;commit;
        delete from covid_diagnoses where num_pat_all_before_admission<v_obfuscation_sml_cnt_delete and num_pat_all_since_admission<v_obfuscation_sml_cnt_delete;commit;
        delete from covid_medications where num_pat_all_before_admission<v_obfuscation_sml_cnt_delete and num_pat_all_since_admission<v_obfuscation_sml_cnt_delete;commit;
    end if;
end;

--******************************************************************************
--******************************************************************************
--*** Finish up
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Set the siteid to a unique value for your institution.
-- * Make sure you are not using another institution's siteid.
-- * The siteid must be no more than 20 letters or numbers.
-- * It must start with a letter.
-- * It cannot have any blank spaces or special characters.
--------------------------------------------------------------------------------
update covid_daily_counts set siteid = (select siteid from covid_config);commit;
update covid_clinical_course set siteid = (select siteid from covid_config);commit;
update covid_demographics set siteid = (select siteid from covid_config);commit;
update covid_labs set siteid = (select siteid from covid_config);commit;
update covid_diagnoses set siteid = (select siteid from covid_config);commit;
update covid_medications set siteid = (select siteid from covid_config);commit;

--------------------------------------------------------------------------------
-- OPTION #1: View the data as tables.
-- * Make sure everything looks reasonable.
-- * Copy into Excel, convert dates into YYYY-MM-DD format, save in csv format.
-- ORACLE: BEGIN/END block does not work unless directly spooling to file or running each select individually
--------------------------------------------------------------------------------
/*
declare
    v_output_as_columns numeric(8,0);
begin
    select output_as_columns into v_output_as_columns from covid_config;
    if v_output_as_columns > 0 then*/
        select * from covid_daily_counts order by calendar_date;
        select * from covid_clinical_course order by days_since_admission;
        select * from covid_demographics order by sex, age_group, race;
        select * from covid_labs order by loinc, days_since_admission;
        select * from covid_diagnoses order by num_pat_all_since_admission desc, num_pat_all_before_admission desc;
        select * from covid_medications order by num_pat_all_since_admission desc, num_pat_all_before_admission desc;
/*    end if;    
end;
*/
--------------------------------------------------------------------------------
-- OPTION #2: View the data as csv strings.
-- * Copy and paste to a text file, save it FileName.csv.
-- * Make sure it is not saved as FileName.csv.txt.
--------------------------------------------------------------------------------
/*
begin
    if exists (select * from covid_config where output_as_csv = 1) then*/
        -- DailyCounts
        select s DailyCountsCSV
            from (
                select 0 i, 'siteid,calendar_date,cumulative_patients_all,cumulative_patients_severe,cumulative_patients_dead,'
                    +'num_pat_in_hosp_on_date,num_pat_in_hospsevere_on_date' s from dual
                union all 
                select row_number() over (order by calendar_date) i,
                    siteid
                    ||','||cast(to_char(calendar_date,'YYYY-MM-DD') as varchar(50)) --YYYY-MM-DD
                    ||','||cast(cumulative_patients_all as varchar(50))
                    ||','||cast(cumulative_patients_severe as varchar(50))
                    ||','||cast(cumulative_patients_dead as varchar(50))
                    ||','||cast(num_pat_in_hosp_on_date as varchar(50))
                    ||','||cast(num_pat_in_hospsevere_on_date as varchar(50))
                from covid_daily_counts
                union all 
                select 9999999, '' from dual--Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
    
        -- ClinicalCourse
        select s ClinicalCourseCSV
            from (
                select 0 i, 'siteid,days_since_admission,num_pat_all_cur_in_hosp,num_pat_ever_severe_cur_hosp' s
                union all 
                select row_number() over (order by days_since_admission) i,
                    siteid
                    ||','||cast(days_since_admission as varchar(50))
                    ||','||cast(num_pat_all_cur_in_hosp as varchar(50))
                    ||','||cast(num_pat_ever_severe_cur_hosp as varchar(50))
                from covid_clinical_course
                union all select 9999999, '' from dual--Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
    
        -- Demographics
        select s DemographicsCSV
            from (
                select 0 i, 'siteid,sex,age_group,race,num_patients_all,num_patients_ever_severe' s
                union all 
                select row_number() over (order by sex, age_group, race) i,
                    siteid
                    ||','||cast(sex as varchar(50))
                    ||','||cast(age_group as varchar(50))
                    ||','||cast(race as varchar(50))
                    ||','||cast(num_patients_all as varchar(50))
                    ||','||cast(num_patients_ever_severe as varchar(50))
                from covid_demographics
                union all select 9999999, '' from dual--Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
    
        -- Labs
        select s LabsCSV
            from (
                select 0 i, 'siteid,loinc,days_since_admission,units,'
                    +'num_patients_all,mean_value_all,stdev_value_all,mean_log_value_all,stdev_log_value_all,'
                    +'num_patients_ever_severe,mean_value_ever_severe,STDEV_VALUE_EVER_SEVERE,mean_log_value_ever_severe,stdev_log_value_ever_severe' s
                union all 
                select row_number() over (order by loinc, days_since_admission) i,
                    siteid
                    ||','||cast(loinc as varchar(50))
                    ||','||cast(days_since_admission as varchar(50))
                    ||','||cast(units as varchar(50))
                    ||','||cast(num_patients_all as varchar(50))
                    ||','||cast(mean_value_all as varchar(50))
                    ||','||cast(stdev_value_all as varchar(50))
                    ||','||cast(mean_log_value_all as varchar(50))
                    ||','||cast(stdev_log_value_all as varchar(50))
                    ||','||cast(num_patients_ever_severe as varchar(50))
                    ||','||cast(mean_value_ever_severe as varchar(50))
                    ||','||cast(STDEV_VALUE_EVER_SEVERE as varchar(50))
                    ||','||cast(mean_log_value_ever_severe as varchar(50))
                    ||','||cast(stdev_log_value_ever_severe as varchar(50))
                from covid_labs
                union all select 9999999, '' from dual--Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
    
        -- Diagnoses
        select s DiagnosesCSV
            from (
                select 0 i, 'siteid,icd_code_3chars,icd_version,'
                    +'num_pat_all_before_admission,num_pat_all_since_admission,'
                    +'num_pat_ever_severe_before_adm,num_pat_ever_severe_since_adm' s
                union all 
                select row_number() over (order by num_pat_all_since_admission desc, num_pat_all_before_admission desc) i,
                    siteid
                    ||','||cast(icd_code_3chars as varchar(50))
                    ||','||cast(icd_version as varchar(50))
                    ||','||cast(num_pat_all_before_admission as varchar(50))
                    ||','||cast(num_pat_all_since_admission as varchar(50))
                    ||','||cast(num_pat_ever_severe_before_adm as varchar(50))
                    ||','||cast(num_pat_ever_severe_since_adm as varchar(50))
                from covid_diagnoses
                union all select 9999999, '' from dual--Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
    
        -- Medications
        select s MedicationsCSV
            from (
                select 0 i, 'siteid,med_class,'
                    +'num_pat_all_before_admission,num_pat_all_since_admission,'
                    +'num_pat_ever_severe_before_adm,num_pat_ever_severe_since_adm' s
                union all 
                select row_number() over (order by num_pat_all_since_admission desc, num_pat_all_before_admission desc) i,
                    siteid
                    ||','||cast(med_class as varchar(50))
                    ||','||cast(num_pat_all_before_admission as varchar(50))
                    ||','||cast(num_pat_all_since_admission as varchar(50))
                    ||','||cast(num_pat_ever_severe_before_adm as varchar(50))
                    ||','||cast(num_pat_ever_severe_since_adm as varchar(50))
                from covid_medications
                union all select 9999999, ''from dual --Add a blank row to make sure the last line in the file with data ends with a line feed.
            ) t
            order by i;
/*    end if;
end*/

/* Oracle scripts based on:
  https://github.com/GriffinWeber/covid19i2b2/blob/master/4CE_Phase1.1_Files_mssql.sql
  commit 64d83bd69c1a4d856c5150c08516d288afce1fb5
Adapted to Oracle by Robert Bradford (UNC-CH) [rbrad@med.unc.edu]
*/
