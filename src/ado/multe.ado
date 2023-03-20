*! version 0.5.0 20Mar2023
*! Multiple Treatment Effects Regression
*! Based code and notes by Michal Kolesár <kolesarmi@googlemail dotcom>
*! Adapted for Stata by Mauricio Caceres Bravo <mauricio.caceres.bravo@gmail.com> and Jerray Chang <jerray@bu.edu>

capture program drop multe
program multe, eclass
    version 14.1

    if replay() {
        Replay `0'
        exit 0
    }

    tempname Womit TWomit Wref TWref
    local 0bak: copy local 0
    syntax varlist(numeric fv ts min=2 max=2)  /// depvar treatment
           [if] [in] [aw fw pw],               /// subset, weights
        control(str)                           /// control variables
    [                                          ///
        vce(str)                               /// SEs to be displayed
        GENerate(str)                          /// save lambdas/taus
        MATAsave(str)                          /// Save resulting mata object
        DECOMPosition                          /// Compute and display decomposition
        minmax                                 /// Print full decomposition table
        overlap                                /// Force overlap (single categorical control only)
        linear                                 /// Assume linear control specification
        debug                                  /// misc debug checks
        flexible                               /// flexible decomposition
    ]

    local decomp1 = ("`decomposition'" != "")
    local decomp2 = (`"`generate'"'    != "")
    local decomp3 = (`"`minmax'"'      != "")
    local decomp  = `decomp1' | `decomp2'

    local vce `vce'
    if !inlist("`vce'", "", "oracle") {
        disp as err "vce() option `vce' not known"
        exit 198
    }

    * Varlist must be depvar and indepvar
    gettoken depvar treatment: varlist
    local depvar    `depvar'
    local treatment `treatment'

    if ( "`linear'" == "" ) {
        cap confirm variable `control'
        if _rc {
            disp as err "existing varlist required for option control()"
            exit _rc
        }
    }
    else if ( "`overlap'" != "" ) {
        disp as err "option overlap cannot be used with option linear"
        exit 198
    }

    * Mark if, in, and any missing values by obs
    local wbak: copy local weight
    local varlist `varlist' `control'
	if ( `"`weight'"' != "" ) {
		tempvar touse wgt
		qui gen double `wgt' `exp' `if' `in'
        local wcall [`weight'=`wgt']
        mark `touse' `if' `in' `wcall'
        markout `touse' `varlist', strok
	}
    else {
        local wcall
        local wgt
        marksample touse, strok
    }

    * Copy to mata for mata fun
    if "`matasave'" == "" local results multe_results
    else local results: copy local matasave

    * Check each control strata has all treatment levels
    * NB: This seems inefficient but doesn't in practice take very long
    qui levelsof `treatment' if `touse', loc(Tlevels)
    local Tk: list sizeof Tlevels

    tempvar T W Wtag Ttag Tuniq Tdrop
    if ( "`linear'" == "" ) {
        qui {
            egen `c(obs_t)' `W'     = group(`control')     if `touse'
            egen byte       `Wtag'  = tag(`W')             if `touse'
            egen byte       `Ttag'  = tag(`W' `treatment') if `touse'
            egen double     `Tuniq' = sum(`Ttag')          if `touse', by(`W')
            gen byte `Tdrop' = (`Tuniq' < `Tk')            if `touse'
        }
        cap assert `Tuniq' <= `Tk' if `touse'
        if ( _rc ) {
            disp as err "found more levels within a control strata than levels overall"
            exit 9
        }

        if ( "`overlap'" != "" ) {
            qui count if (`Wtag' == 1) & (`Tdrop' == 1) & `touse'
            local nstrata = `r(N)'
            qui count if (`Tdrop' == 1) & `touse'
            local nobs = `r(N)'
            qui replace `touse' = 0 if (`Tdrop' == 1)
            if ( `nobs' | `nstrata' ) {
                disp as txt "dropped `nstrata' control strata without sufficient overlap (`nobs' obs)"
            }
            qui drop `W'
            qui egen `c(obs_t)' `W' = group(`control') if `touse'
        }

        qui egen `c(obs_t)' `T' = group(`treatment') if `touse'
        fvexpand ibn.`W' if `touse'
        local Wi `r(varlist)'
    }
    else {
        qui egen `c(obs_t)' `T' = group(`treatment') if `touse'

        local 0bak: copy local 0
        local 0 `control'
        cap syntax varlist(numeric fv ts)
        if _rc {
            disp as err "Numeric varlist required with option -lienar-"
            exit _rc
        }

        helper_reference_omitted `control' if `touse'
        matrix `Wref' = r(omit)
        helper_strip_omitted `control' if `touse' `wcall', extra(b1.`T')
        matrix `Womit' = r(omit)
        local 0: copy local 0bak
        local weight: copy local wbak
        local W `r(expanded)'

        tempvar cons
        qui gen byte `cons' = 1
        mata st_local("Wi", any(!st_matrix(st_local("Womit")))? invtokens(select(tokens(st_local("W")), !st_matrix(st_local("Womit")))): "")
        local Wi `cons' `Wi'
    }

    qui count if `touse'
    if ( `r(N)' == 0 ) {
        disp as txt "insufficient observations for estimation"
        exit 498
    }

    * Interaction collinearity check (might still be able to run everything)
    * local base = 1
    * local TiWi
    * foreach Tj of local Tlevels {
    *     if ( `base' ) {
    *         local TiWi `TiWi' `Tj'bn.`treatment'#c.(`Wi')
    *     }
    *     else {
    *         local TiWi `TiWi' `Tj'.`treatment'#c.(`Wi')
    *     }
    * }
    * helper_strip_omitted `TiWi' if `touse' `wcall', noconstant
    * matrix `TWomit' = r(omit)
    * local TW `r(expanded)'
    disp _n(1) "Checking for collinear columns in interacted specification..."
    helper_reference_omitted ibn.`T'#c.(`Wi') if `touse'
    matrix `TWref' = r(omit)
    helper_strip_omitted ibn.`T'#c.(`Wi') if `touse' `wcall', noconstant
    matrix `TWomit' = r(omit)
    local TW `r(expanded)'

    mata {
        if ( any(select(st_matrix(st_local("TWomit")), st_matrix(st_local("TWref")))) ) {
            printf("(note: temp variable `T' was created for the collinearity check and\n")
            printf("contains factors 1 through `Tk' corresponding to the levels of `treatment')\n")
        }
    }

    mata `results' = MulTE()
    mata `results'.estimates("`depvar'", "`treatment'", "`W'", "`touse'", "`wgt'", "`weight'")
    mata `results'.estimates.wgtvar = st_local("exp")

    if ( `decomp' ) {
        mata `results'.decomposition("`depvar'", "`treatment'", "`W'", "`touse'", "`wgt'", "`weight'")
        mata `results'.decomposition.wgtvar = st_local("exp")

        * Save lambda and tauhat, if requested
        LambdaTau, results(`results') touse(`touse') `generate'
    }
    mata `results'.cache_drop()

    * Save estimates in r()
    tempname estmatrix decompmatrix
    mata `results'.estimates.save("`estmatrix'")
    mata `results'.decomposition.save("`decompmatrix'")

    * Display standard Stata table; save in e()
    Display `results', vce(`vce') touse(`touse')
    mata st_local("cmdline", "multe " + st_local("0bak"))
    ereturn local cmdline: copy local cmdline
    ereturn local wtype     = "`weight'"
    ereturn local wexp      = "`exp'"
    ereturn local cmd       = "multe"
    ereturn local depvar    = "`depvar'"
    ereturn local treatment = "`treatment'"
    ereturn local control   = "`control'"
    ereturn local mata      = "`results'"

    ereturn matrix estimates = `estmatrix'
    if ( `decomp' ) {
        ereturn matrix decomposition = `decompmatrix'
        if ( `decomp1' ) {
            mata `results'.decomposition.print(`decomp3')
        }
    }
end

capture program drop LambdaTau
program LambdaTau
    syntax, results(str) [lambda LAMBDAprefix(str) tau TAUprefix(str) touse(str)]
    tempname types names

    local savelambda = ("`lambdaprefix'" != "") | ("`lambda'" != "")
    local savetau    = ("`tauprefix'"    != "") | ("`tau'"    != "")

    if "`lambdaprefix'" == "" local lambdaprefix lambda
    if "`tauprefix'"    == "" local tauprefix    tau

    if ( `savelambda' ) {
        mata: `names' = `results'.decomposition.lambda_names
        mata: `names' = "`lambdaprefix'" :+ `names'
        mata: `types' = J(1, cols(`names'), "`:set type'")
        mata: (void) st_addvar(`types', `names')
        if "`touse'" != "" {
            mata: (void) st_store(., `names', "`touse'", `results'.decomposition.lambda(`results'.Xm, `results'.Wm, `results'.w))
        }
        else {
            mata: (void) st_store(., `names', `results'.decomposition.lambda(`results'.Xm, `results'.Wm, `results'.w))
        }
    }

    if ( `savetau' ) {
        mata: `names' = `results'.decomposition.tauhat_names
        mata: `names' = "`tauprefix'" :+ `names'
        mata: `types' = J(1, cols(`names'), "`:set type'")
        mata: (void) st_addvar(`types', `names')
        if "`touse'" != "" {
            mata: (void) st_store(., `names', "`touse'", `results'.decomposition.tauhat(`results'.Wm))
        }
        else {
            mata: (void) st_store(., `names', `results'.decomposition.tauhat(`results'.Wm))
        }
    }
end

capture program drop Replay
program Replay, eclass
    syntax, [vce(str) GENerate(str) DECOMPosition minmax *]
    local decomp1 = ("`decomposition'" != "")
    local decomp2 = (`"`generate'"'    != "")
    local decomp3 = (`"`minmax'"'      != "")
    local decomp  = `decomp1' | `decomp2'
    if (`"`e(cmd)'"' != "multe") error 301
    if ( `decomp' ) {
        Decomposition, `generate'
        if ( `decomp1' ) {
            mata `e(mata)'.decomposition.print(`decomp3')
        }
        tempname decompmatrix
        mata `e(mata)'.decomposition.save("`decompmatrix'")
        ereturn matrix decomposition = `decompmatrix'
    }
    else {
        Display `e(mata)', vce(`vce') repost `options'
    }
end

capture program drop Decomposition
program Decomposition
    syntax, [*]
    tempvar touse W
    qui gen byte `touse' = e(sample)
    if "`e(wexp)'" != "" {
        tempvar wgt
        qui gen double `wgt' `e(wexp)' if `touse'
    }
    qui egen `c(obs_t)' `W' = group(`e(control)') if `touse'
    mata `e(mata)'.cache_load("`e(depvar)'", "`e(treatment)'", "`W'", "`touse'", "`wgt'")
    mata `e(mata)'.decomposition("`e(depvar)'", "`e(treatment)'", "`W'", "`touse'", "`wgt'", "`e(wtype)'")
    LambdaTau, results(`e(mata)') `options' touse(`touse')
    mata `e(mata)'.cache_drop()
end

capture program drop Display
program Display, eclass
    syntax namelist(max = 1), [vce(str) touse(str) repost *]
    * mata printf("\nTreatment Effect Estimates\n")
    if "`post'" == "" local post post
    FreeMatrix b V
    mata `namelist'.estimates.post("`b'", "`V'", "`vce'")
    mata st_local("N", strofreal(`namelist'.estimates.n))
    if "`repost'" == "repost" {
        ereturn repost b = `b' V = `V'
    }
    else {
        ereturn post `b' `V', esample(`touse') obs(`N')
    }

    if ( "`vce'" == "oracle" ) ereturn local vcetype "Oracle"
    else ereturn local vcetype ""
    ereturn local vce `vce'

    _coef_table_header, nomodeltest title(Treatment Effect Estimates)
    disp ""
    _coef_table, noempty `options'
    //     level(95)
    //     bmatrix(`b')      // e(b)
    //     vmatrix(`V')      // e(V)
    //     dfmatrix(matname) // e(mi_df)
    //     ptitle(title)
    //     coeftitle(title)
    //     cititle(title)
    //     cformat(format)
    //     pformat(format)
    //     sformat(format)
end

capture program drop FreeMatrix
program FreeMatrix
    local FreeCounter 0
    local FreeMatrix
    foreach FM of local 0 {
        cap error 0
        while ( _rc == 0 ) {
            cap confirm matrix MulTE`++FreeCounter'
            c_local `FM' MulTE`FreeCounter'
        }
    }
end

capture program drop helper_reference_omitted
program helper_reference_omitted, rclass
    syntax anything(equalok) [if] [in]
    fvexpand `anything' `if' `in'
    local expanded `r(varlist)'

    tempname b omit
    matrix `b' = J(1, `:list sizeof expanded', .)
    matrix colnames `b' = `expanded'

    _ms_omit_info `b'
    matrix `omit' = r(omit)

    return local expanded: copy local expanded
    return matrix omit = `omit'
end

capture program drop helper_strip_omitted
program helper_strip_omitted, rclass
    syntax anything(equalok) [if] [aw fw pw], [extra(str) *]
	if ( `"`weight'"' != "" ) local wcall [`weight' `exp']
    fvexpand `extra'
    local extra `r(varlist)'
    _rmcoll `extra' `anything' `if' `wcall', expand `options'
    local expanded `r(varlist)'

    tempname b omit final keep
    mata `keep' = (`:list sizeof extra'+1)..`:list sizeof expanded'
    matrix `b' = J(1, `:list sizeof expanded', .)
    matrix colnames `b' = `expanded'
    matrix `b' = `b'[1,(`:list sizeof extra'+1)..`:list sizeof expanded']

    _ms_omit_info `b'
    matrix `omit' = r(omit)
    mata `final' = select(st_matrixcolstripe("`b'")[., 2]', !st_matrix("r(omit)"))
    mata st_local("varlist",  invtokens(cols(`final')? `final': ""))
    mata st_local("expanded", invtokens(tokens(st_local("expanded"))[`keep']))

    return local expanded: copy local expanded
    return local varlist:  copy local varlist
    return matrix omit =  `omit'
end
