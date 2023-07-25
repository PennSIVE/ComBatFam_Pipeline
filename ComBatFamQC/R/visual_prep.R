require(stats)
require(lme4)
require(pbkrtest)
require(parallel)
require(Rtsne)
require(MDMR)
require(mgcv)
require(dplyr)
require(tidyverse)
require(tidyr)
require(car)
require(stringr)

#' Batch Effect Visualization Datasets Preparation
#'
#' Prepare relevant datasets for batch/site effect visualization.
#'
#' @param type A model function name that is used or to be used in the ComBatFamily Package (eg: "lmer", "lm").
#' @param features Features to be harmonized. \emph{n x p} data frame or matrix of observations where \emph{p} is the number of features and \emph{n} is the number of subjects.
#' @param batch Factor indicating batch (often equivalent to site or scanner).
#' @param covariates Name of covariates supplied to `model`.
#' @param interaction Expression of interaction terms supplied to `model` (eg: "age*diagnosis").
#' @param random Variable name of a random effect in linear mixed effect model.
#' @param smooth Variable name that requires a smooth function.
#' @param smooth_int_type Indicates the type of interaction in `gam` models. By default, smooth_int_type is set to be "linear", representing linear interaction terms. "factor-smooth" represents categorical-continuous interactions and "tensor" represents interactions with different scales.
#' @param df Dataset to be harmonized.
#' @param cov A boolean variable indicates whether a covfam harmonization is considered.
#' @param ... Additional arguments to `comfam` or `covfam` models.
#'
#' @return `visual_prep` returns a list containing the following components:
#' \item{summary_df}{Batch sample size summary}
#' \item{residual_add_df}{Residuals that might contain additive and multiplicative joint batch effects}
#' \item{residual_ml_df}{Residuals that might contain multiplicative batch effect}
#' \item{pr.feature}{PCA results}
#' \item{pca_df}{A dataframe contains features in the form of PCs}
#' \item{tsne_df}{A dataframe prepared for T-SNE plots}
#' \item{kr_test_df}{A dataframe contains Kenward-Roger(KR) test results}
#' \item{fk_test_df}{A dataframe contains Fligner-Killeen(FK) test results}
#' \item{mdmr.summary}{A dataframe contains MDMR results}
#' \item{anova_test_df}{A dataframe contains ANOVA test results}
#' \item{kw_test_df}{A dataframe contains Kruskal-Wallis test results}
#' \item{lv_test_df}{A dataframe contains Levene's test results}
#' \item{bl_test_df}{A dataframe contains Bartlett's test results}
#' \item{red}{A parameter to highlight significant p-values in result table}
#' \item{info}{A list contains input information like batch, covariates, df etc}
#' \item{eb_df}{A dataframe contains empirical Bayes estimates}
#'
#' @import tidyverse
#' @import tidyr
#' @import dplyr
#' @import pbkrtest
#' @import parallel
#' @import Rtsne
#' @import MDMR
#' @import ComBatFamily
#' @import stringr
#' @importFrom broom tidy
#' @importFrom mgcv gam anova.gam
#' @importFrom gamlss gamlss
#' @importFrom quantreg rq
#' @importFrom lme4 lmer
#' @importFrom methods hasArg
#' @importFrom stats family lm median model.matrix prcomp predict qnorm update var anova as.formula coef dist fligner.test p.adjust resid na.omit bartlett.test kruskal.test
#' @importFrom car leveneTest
#' 
#' @export

visual_prep <- function(type, features, batch, covariates, interaction = NULL, random = NULL, smooth = NULL, smooth_int_type = "linear", df, cov = FALSE, ...){
  # Save info
  ## Characterize/factorize categorical variables
  df = na.omit(df)
  df[[batch]] = as.factor(df[[batch]])
  char_var = covariates[sapply(df[covariates], function(col) is.character(col) || is.factor(col))]
  enco_var = covariates[sapply(df[covariates], function(col) length(unique(col)) == 2 && all(unique(col) %in% c(0,1)))]
  df[char_var] =  lapply(df[char_var], as.factor)
  df[enco_var] =  lapply(df[enco_var], as.factor)
  cov_shiny = covariates
  char_var = c(char_var, enco_var)
  if(!is.null(random)){
    #df[[random]] = as.factor(df[[random]])
    for (r in random){
      df[[r]] = as.factor(df[[r]])
    }
  }
  
  if(!is.null(interaction)){
    if(type == "lmer"){
      #df[random] = sapply(random, function(x) as.factor(df[[x]]), USE.NAMES = FALSE)
      interaction = gsub(",", ":", interaction)
    }else if(type == "gam"){
      covariates = setdiff(covariates, smooth)
      if(smooth_int_type == "linear"){
        interaction = gsub(",", ":", interaction)
      }else if(smooth_int_type == "categorical-continuous"){
        element = lapply(interaction, function(x) str_split(x,",")[[1]])
        smooth_element = lapply(element, function(x) x[which(x %in% smooth)])
        categorical_element = lapply(1:length(element), function(i) setdiff(element[[i]], smooth_element[[i]]))
        interaction = lapply(1:length(element), function(i) paste0("s(", smooth_element[[i]], ", by = ", categorical_element[[i]], ")")) %>% unlist()
        smooth = setdiff(smooth, unique(unlist(smooth_element)))
      }else if(smooth_int_type == "factor-smooth"){
        interaction = paste("s(", interaction, ", bs = 'fs')")
        smooth_index = sapply(smooth, function(x){
          if(sum(grepl(x, interaction)) > 0){return(1)}else(return(0))
        }, USE.NAMES = FALSE)
        cov_index = sapply(covariates, function(x){
          if(sum(grepl(x, interaction)) > 0){return(1)}else(return(0))
        }, USE.NAMES = FALSE)
        smooth = smooth[which(smooth_index == 0)]
        covariates = covariates[which(cov_index == 0)]
      }else if(smooth_int_type == "tensor"){
        interaction = paste("ti(", interaction, ")")
      }
    }else if(type == "lm"){interaction = gsub(",", ":", interaction)}
  }
  
  info = list("batch" = batch, "features" = features, "type" = type, "covariates" = covariates, "interaction" = interaction, "random" = random, "smooth" = smooth, "df" = df, "cov_shiny" = cov_shiny, "char_var" = char_var)
  
  # Summary
  summary_df = df %>% group_by(eval(parse(text = batch))) %>% summarize(count = n(), percentage = 100*count/nrow(df))
  colnames(summary_df) = c(batch, "count", "percentage (%)")
  
  # Residual Plots
  vis_df = df[colnames(df)[!colnames(df) %in% features]]
  residual_add_df = mclapply(features, function(y){
    model = model_gen(y = y, type = type, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    if(type == "lmer"){
      coef_list = coef(model)
      intercept = lapply(1:length(coef_list), function(i){
        b = coef_list[[i]]
        b_fix = unique(b[,-1])
        b_fix_ex = b_fix[which(!grepl(paste0(batch,"*"), names(b_fix)))]
        b[[random[i]]] = as.factor(rownames(b))
        sub_coef = df[random[i]] %>% left_join(b[c(random[i], "(Intercept)")], by = c(random[i]))
        colnames(sub_coef) = c(random[i], paste0(random[i], "_int"))
        return(sub_coef)
      }) %>% bind_cols() %>% dplyr::select(matches("_int$"))
      b = coef(model)[[1]]
      b_fix = unique(b[,-1])
      b_fix_ex = b_fix[which(!grepl(paste0(batch,"*"), names(b_fix)))]
      y_hat = model.matrix(model)[, which(!grepl(paste0(batch,"*|(Intercept)"), colnames(model.matrix(model))))] %*% t(b_fix_ex) 
      for (i in 1:length(random)){
        y_hat = y_hat + intercept[[i]]
      }
    }else{
      b = coef(model)
      b = b[-1]
      b = b[which(!grepl(paste0(batch,"*"), names(b)))]
      if(length(b) > 1){
        y_hat = model.matrix(model)[, which(!grepl(paste0(batch,"*|(Intercept)"), colnames(model.matrix(model))))] %*% b}else{
          y_hat = model.matrix(model)[, which(!grepl(paste0(batch,"*|(Intercept)"), colnames(model.matrix(model))))] * b
        }
    }
    residual = data.frame(df[[y]] - y_hat)
    colnames(residual) = y
    return(residual)
  }, mc.cores = detectCores()) %>% bind_cols()
  residual_add_df = cbind(vis_df, residual_add_df)
  
  residual_ml_df = mclapply(features, function(y){
    model = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    residual = data.frame(resid(model))
    colnames(residual) = y
    return(residual)
  }) %>% bind_cols()
  residual_ml_df = cbind(vis_df, residual_ml_df)
  
  # PCA Plots
  pr.feature = prcomp(x = residual_add_df[features], scale = TRUE, center = TRUE)
  pca_df = cbind(vis_df, pr.feature$x)
  
  # T-SNE Plots
  tsne_out = Rtsne(as.matrix(residual_add_df[features]))
  tsne_df = cbind(vis_df, tsne_out$Y)
  colnames(tsne_df) = c(colnames(vis_df), "cor_1", "cor_2")
  # Statistical Test
  
  ## Kenward-Roger(KR) Test
  if(type == "lmer"){
    kr_test_df = mclapply(features, function(y){
      lmm1 = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
      lmm2 = update(lmm1, as.formula(paste0(".~. -", batch)))
      kr.test = KRmodcomp(lmm1, lmm2)
      kr_df = kr.test %>% tidy() %>% filter(type == "Ftest") %>% mutate(feature = y) %>% dplyr::select(feature, stat, ndf, ddf, p.value) 
      return(kr_df)
    }, mc.cores = detectCores()) %>% bind_rows()
    kr_test_df$p.value = p.adjust(kr_test_df$p.value, method = "bonferroni", n = length(kr_test_df$p.value))
    kr_test_df = kr_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                       p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                       p.value < 0.001 ~ "***",
                                                       .default = NA))
    
    kr_test_df = kr_test_df %>% mutate(stat = round(stat, 2), ddf = round(ddf, 2))
    kr_test_df$p.value = sapply(kr_test_df$p.value, function(x){
      ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
    }, USE.NAMES = FALSE)
    unique_kr = unique(kr_test_df$p.value)[unique(kr_test_df$p.value) != "<0.001"][which(as.numeric(unique(kr_test_df$p.value)[unique(kr_test_df$p.value) != "<0.001"]) < 0.05)]
  }else{
    kr_test_df = data.frame("feature" = NULL, "stat" = NULL, "ndf" = NULL, "ddf" = NULL, "p.value" = NULL, "sig" = NULL)
    unique_kr = unique(kr_test_df$p.value)[unique(kr_test_df$p.value) != "<0.001"][which(as.numeric(unique(kr_test_df$p.value)[unique(kr_test_df$p.value) != "<0.001"]) < 0.05)]
  }
  
  ## Fligner-Killeen(FK) Test
  fk_test_df = mclapply(features, function(y){
    lmm_multi = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    fit_residuals <- resid(lmm_multi)
    FKtest = fligner.test(fit_residuals ~ df[[batch]])
    fk_df = FKtest %>% tidy() %>% dplyr::select(p.value) %>% mutate(feature = y)
    fk_df = fk_df[c(2,1)]
    return(fk_df)
  }, mc.cores = detectCores()) %>% bind_rows()
  fk_test_df$p.value = p.adjust(fk_test_df$p.value, method = "bonferroni", n = length(fk_test_df$p.value))
  fk_test_df = fk_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                     p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                     p.value < 0.001 ~ "***",
                                                     .default = NA))
  fk_test_df$p.value = sapply(fk_test_df$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  unique_fk = unique(fk_test_df$p.value)[unique(fk_test_df$p.value) != "<0.001"][which(as.numeric(unique(fk_test_df$p.value)[unique(fk_test_df$p.value) != "<0.001"]) < 0.05)]
  
  ## MDMR
  D = dist(as.matrix(residual_add_df[features]))
  mdmr.res = mdmr(X = as.matrix(residual_add_df[batch]), D = D)
  mdmr.summary = summary(mdmr.res)
  colnames(mdmr.summary) = c("Statistic", "Numer.DF", "Pseudo.R2", "p.value")
  mdmr.summary = mdmr.summary %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                         p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                         p.value < 0.001 ~ "***",
                                                         .default = NA))
  mdmr.summary$p.value = sapply(mdmr.summary$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  mdmr.summary = mdmr.summary %>% mutate(Statistic = round(Statistic, 2),Pseudo.R2 = round(Pseudo.R2, 2))
  unique_mdmr = unique(mdmr.summary$p.value)[unique(mdmr.summary$p.value) != "<0.001"][which(as.numeric(unique(mdmr.summary$p.value)[unique(mdmr.summary$p.value) != "<0.001"]) < 0.05)]
  
  
  ## ANOVA 
  anova_test_df = mclapply(features, function(y){
    lmm1 = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    lmm2 = update(lmm1, as.formula(paste0(".~. - ", batch)))
    if(type == "gam"){
      anova.test = anova.gam(lmm2, lmm1, test = "F")
    }else{
      anova.test = anova(lmm2, lmm1)}
    if(type != "lmer"){
      p = anova.test[["Pr(>F)"]][2]}else{
        p = anova.test %>% tidy() %>% pull(p.value)
      }
    anova_df = data.frame(cbind(y, p[length(p)]))
    colnames(anova_df) = c("feature", "p.value")
    return(anova_df)
  }, mc.cores = detectCores()) %>% bind_rows()
  anova_test_df$p.value = p.adjust(anova_test_df$p.value, method = "bonferroni", n = length(anova_test_df$p.value))
  anova_test_df = anova_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                           p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                           p.value < 0.001 ~ "***",
                                                           .default = NA))
  anova_test_df$p.value = sapply(anova_test_df$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  unique_anova = unique(anova_test_df$p.value)[unique(anova_test_df$p.value) != "<0.001"][which(as.numeric(unique(anova_test_df$p.value)[unique(anova_test_df$p.value) != "<0.001"]) < 0.05)]
  
  ## Kruskal-Wallis 
  kw_test_df = mclapply(features, function(y){
    KWtest = kruskal.test(residual_add_df[[y]] ~ residual_add_df[[batch]])
    kw_df = KWtest %>% tidy() %>% dplyr::select(p.value) %>% mutate(feature = y) 
    kw_df = kw_df[c(2,1)]
    return(kw_df)
  }, mc.cores = detectCores()) %>% bind_rows()
  kw_test_df$p.value = p.adjust(kw_test_df$p.value, method = "bonferroni", n = length(kw_test_df$p.value))
  kw_test_df = kw_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                                          p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                                          p.value < 0.001 ~ "***",
                                                                          .default = NA))
  kw_test_df$p.value = sapply(kw_test_df$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  unique_kw = unique(kw_test_df$p.value)[unique(kw_test_df$p.value) != "<0.001"][which(as.numeric(unique(kw_test_df$p.value)[unique(kw_test_df$p.value) != "<0.001"]) < 0.05)]
  
  ## Levene's Test
  lv_test_df = mclapply(features, function(y){
    lmm_multi = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    fit_residuals = resid(lmm_multi)
    LVtest = leveneTest(fit_residuals ~ as.factor(df[[batch]]))
    lv_df = LVtest %>% tidy() %>% dplyr::select(p.value) %>% mutate(feature = y) 
    lv_df = lv_df[c(2,1)]
    return(lv_df)
  }, mc.cores = detectCores()) %>% bind_rows()
  lv_test_df$p.value = p.adjust(lv_test_df$p.value, method = "bonferroni", n = length(lv_test_df$p.value))
  lv_test_df = lv_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                     p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                     p.value < 0.001 ~ "***",
                                                     .default = NA))
  lv_test_df$p.value = sapply(lv_test_df$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  unique_lv = unique(lv_test_df$p.value)[unique(lv_test_df$p.value) != "<0.001"][which(as.numeric(unique(lv_test_df$p.value)[unique(lv_test_df$p.value) != "<0.001"]) < 0.05)]
  
  ## Bartlett's Test
  bl_test_df = mclapply(features, function(y){
    lmm_multi = model_gen(type = type, y = y, batch = batch, covariates = covariates, interaction = interaction, random = random, smooth = smooth, df = df)
    fit_residuals = resid(lmm_multi)
    BLtest = bartlett.test(fit_residuals ~ as.factor(df[[batch]]))
    bl_df = BLtest %>% tidy() %>% dplyr::select(p.value) %>% mutate(feature = y) 
    bl_df = bl_df[c(2,1)]
    return(bl_df)
  }, mc.cores = detectCores()) %>% bind_rows()
  bl_test_df$p.value = p.adjust(bl_test_df$p.value, method = "bonferroni", n = length(bl_test_df$p.value))
  bl_test_df = bl_test_df %>% arrange(p.value) %>% mutate(sig = case_when(p.value < 0.05 & p.value >= 0.01 ~ "*",
                                                                          p.value < 0.01 & p.value >= 0.001 ~ "**",
                                                                          p.value < 0.001 ~ "***",
                                                                          .default = NA))
  bl_test_df$p.value = sapply(bl_test_df$p.value, function(x){
    ifelse(x >= 0.001, sprintf("%.2f", round(x, 2)), "<0.001")
  }, USE.NAMES = FALSE)
  unique_bl = unique(bl_test_df$p.value)[unique(bl_test_df$p.value) != "<0.001"][which(as.numeric(unique(bl_test_df$p.value)[unique(bl_test_df$p.value) != "<0.001"]) < 0.05)]
  red = c(unique_kr, unique_fk, unique_mdmr, unique_anova, unique_kw, unique_lv, unique_bl, "<0.001")
  
  # Empirical Estimates
  form = form_gen(x = type, c = df[covariates], i = interaction, random = random, smooth = smooth, int_type = smooth_int_type)
  if(!cov){
    if(type == "lmer"){
      ComBat_run = ComBatFamily::comfam(data = df[features],
                                    bat = df[[batch]], 
                                    covar = cbind(df[cov_shiny], df[random]),
                                    model = eval(parse(text = type)), 
                                    formula = as.formula(form), ...)}else{
     ComBat_run = ComBatFamily::comfam(data = df[features],
                                    bat = df[[batch]], 
                                    covar = cbind(df[cov_shiny]),
                                    model = eval(parse(text = type)), 
                                    formula = as.formula(form), ...)
                                    }
    gamma_hat = ComBat_run$estimates$gamma.hat
    delta_hat = ComBat_run$estimates$delta.hat
    gamma_star = ComBat_run$estimates$gamma.star
    delta_star = ComBat_run$estimates$delta.star
    batch_name = rownames(gamma_hat)
    eb_list = list(gamma_hat, delta_hat, gamma_star, delta_star)
    eb_name = c("gamma_hat", "delta_hat", "gamma_star", "delta_star")
    eb_df = lapply(1:4, function(i){
      eb_df_long = data.frame(eb_list[[i]]) %>% mutate(batch = as.factor(batch_name), .before = 1) %>% tidyr::pivot_longer(2:(dim(eb_list[[i]])[2]+1), names_to = "features", values_to = "eb_values") %>% mutate(type = eb_name[i]) 
      return(eb_df_long)
    }) %>% bind_rows()
  }else{
    if(type == "lmer"){
      ComBat_run = ComBatFamily::covfam(data = df[features],
                                      bat = df[[batch]] , 
                                      covar = cbind(df[cov_shiny], df[random]),
                                      model = eval(parse(text = type)), 
                                      formula = as.formula(form),
                                      ...)
    }else{
      ComBat_run = ComBatFamily::covfam(data = df[features],
                                        bat = df[[batch]] , 
                                        covar = df[cov_shiny],
                                        model = eval(parse(text = type)), 
                                        formula = as.formula(form),
                                        ...)
    }
    gamma_hat = ComBat_run$combat.out$estimates$gamma.hat
    delta_hat = ComBat_run$combat.out$estimates$delta.hat
    gamma_star = ComBat_run$combat.out$estimates$gamma.star
    delta_star = ComBat_run$combat.out$estimates$delta.star
    score_gamma_hat = ComBat_run$scores.combat$estimates$gamma.hat
    score_delta_hat = ComBat_run$scores.combat$estimates$delta.hat
    score_gamma_star = ComBat_run$scores.combat$estimates$gamma.star
    score_delta_star = ComBat_run$scores.combat$estimates$delta.star
    batch_name = rownames(gamma_hat)
    eb_list = list(gamma_hat, delta_hat, gamma_star, delta_star, score_gamma_hat, score_delta_hat, score_gamma_star, score_delta_star)
    eb_name = c("gamma_hat", "delta_hat", "gamma_star", "delta_star", "score_gamma_hat", "score_delta_hat", "score_gamma_star", "score_delta_star")
    eb_df = lapply(1:8, function(i){
      eb_df_long = data.frame(eb_list[[i]]) %>% mutate(batch = as.factor(batch_name), .before = 1) %>% tidyr::pivot_longer(2:(dim(eb_list[[i]])[2]+1), names_to = "features", values_to = "eb_values") %>% mutate(type = eb_name[i]) 
      return(eb_df_long)
    }) %>% bind_rows()
  }
  
  # Result
  result = list("summary_df" = summary_df, "residual_add_df" = residual_add_df, "residual_ml_df" = residual_ml_df, "pr.feature" = pr.feature, "pca_df" = pca_df, "tsne_df" = tsne_df, "kr_test_df" = kr_test_df, "fk_test_df" = fk_test_df, "mdmr.summary" = mdmr.summary, 
                "anova_test_df" = anova_test_df, "kw_test_df" = kw_test_df, "lv_test_df" = lv_test_df, "bl_test_df" = bl_test_df, "red" = red, "info" = info, "eb_df" = eb_df)
  return(result)
}

#' Model generations
#'
#' Generate appropriate regression models based on the model type and formula
#'
#' @param y Dependent variable in the model.
#' @param type A model function name that is used or to be used in the ComBatFamily Package (eg: "lmer", "lm").
#' @param batch Factor indicating batch (often equivalent to site or scanner).
#' @param covariates Name of covariates supplied to `model`.
#' @param interaction Expression of interaction terms supplied to `model` (eg: "age*diagnosis").
#' @param random Variable name of a random effect in linear mixed effect model.
#' @param smooth Variable name that requires a smooth function.
#' @param df Dataset to be harmonized.
#'
#' @return A model object
#' 
#' @export

model_gen <- function(y, type, batch, covariates, interaction = NULL, random = NULL, smooth = NULL, df){
  if(type == "lmer"){
    if(is.null(interaction)){
      model = lmer(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", batch, " + ", paste("(1 |", random, ")", collapse = " + "))), data = df)
    }else{
      model = lmer(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", paste(interaction, collapse = " + "), " + ", batch, " + ", paste("(1 |", random, ")", collapse = " + "))), data = df)}
  }else if(type == "lm"){
    if(is.null(interaction)){
      model = lm(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", batch)), data = df)
    }else{
      model = lm(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", paste(interaction, collapse = " + "), " + ", batch)), data = df)}
  }else if(type == "gam"){
    if(is.null(interaction)){
      model = gam(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", paste("s(", smooth, ")", collapse = " + "), " + ", batch)), data = df)
    }else{
      if(length(smooth) > 0){
        model = gam(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", paste("s(", smooth, ")", collapse = " + "), " + ", paste(interaction, collapse = " + "), " + ", batch)), data = df)
      }else{
        model = gam(as.formula(paste0(y, " ~ ", paste(covariates, collapse = " + "), " + ", paste(interaction, collapse = " + "), " + ", batch)), data = df)
        }
      }
  }
  return(model)
}

#' ComBatFam Formula generations
#'
#' Generate appropriate formula for ComBatFam models
#'
#' @param x A model function name that is used or to be used in the ComBatFamily Package (eg: "lmer", "lm").
#' @param c Data frame or matrix of covariates supplied to `model`
#' @param i Expression of interaction terms supplied to `model`, using comma to separate terms. (eg: "age,diagnosis").
#' @param random Variable name of a random effect in linear mixed effect model.
#' @param smooth Variable name that requires a smooth function.
#' @param int_type Indicates the type of interaction in `gam` models. By default, smooth_int_type is set to be "linear", representing linear interaction terms. "factor-smooth" represents categorical-continuous interactions and "tensor" represents interactions with different scales.
#'
#' @return A string of formula 
#' 
#' @export
form_gen = function(x, c, i, random, smooth, int_type){
  if (x == "lm"){
    if(!is.null(c)){
      if (is.null(i)){form = paste0("y ~", paste(colnames(c), collapse = "+"))}else{
        form = paste0("y ~", paste(colnames(c), collapse = "+"),  " + ", paste(i, collapse = " + "))
      }
    }else{form = NULL}
  }else if (x == "lmer"){
    if(!is.null(c)){
      if (is.null(i)){form = paste0("y ~", paste(colnames(c), collapse = " + "),  " + ", paste("(1 |", random, ")", collapse = " + "))}else{
        form = paste0("y ~", paste(colnames(c), collapse = " + "),  " + ", paste(i, collapse = " + "), " + ", paste("(1 |", random, ")", collapse = " + "))
      }
    }else{form = paste0("y ~", paste("(1 |", random, ")", collapse = " + "))}
  }else if(x == "gam"){
    if (is.null(i)){form = paste0("y ~ ", paste(colnames(c), collapse = " + "), " + ", paste("s(", smooth, ")", collapse = " + "))}else{
      if(length(smooth) > 0){
        form = paste0("y ~ ", paste(colnames(c), collapse = " + "), " + ", paste("s(", smooth, ")", collapse = " + "), " + ", paste(i, collapse = " + "))
      }else{
        form = paste0("y ~ ", paste(colnames(c), collapse = " + "), " + ", paste(i, collapse = " + "))
      }
    }
  }
  return(form)
}


utils::globalVariables(c("feature", "stat", "ndf", "ddf", "F.scaling", "p.value", "Statistic", "Pseudo.R2","cor_1", "cor_2", "Numer.DF"))